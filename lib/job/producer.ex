defmodule RAP.Job.Producer do
  @moduledoc """
  This is the job producer stage of the RAP. Strictly speaking, the
  producer stage of the RAP proper is the monitoring of the storage
  backend. Given a turtle manifest path, attempt to read this into an RDF
  graph, and then load it into a struct.

  There are a few checks that we need to do before we can decide to run a
  job. These are as follows:

  1. Read the manifest, inject it into the ManifestDesc struct and check
     it's non-empty. There are circumstances in which Grax.load generates
     an empty struct, e.g. when the name is valid in the vocabulary and
     certain fields are not required.     

  2. Check that the tables section references real tables, or at least
     what we've been able to find in the cache directory under the
     manifest UUID.

  3. Check that the tables referenced in the columns section are real
     tables. The columns also have a notion of an underlying variable
     which we may want to check later, but it's better to let this be
     overridden for now because we only care about pattern matching and
     don't peer into the structure, although warning that these don't
     exist may be productive later.

  4. Good error messages and return behaviour help us to correct issues
     with our job manifests so it is important to have a way to compare
     good and bad table / column scope at the end. This isn't especially
     elegant as the errors need to be included in the function return
     values, so that it's clear at the end of the stage what, if anything
     went wrong.
  """

  alias RAP.Manifest.{TableDesc, ScopeDesc, JobDesc, ManifestDesc}
  alias RAP.Storage.{MidRun, GCP}
  alias RAP.Job.{ScopeSpec, ResourceSpec, TableSpec, JobSpec, ManifestSpec}
  alias RAP.Provenance.Work
    
  use GenStage
  require Logger

  @type stage_dispatcher   :: GenStage.BroadcastDispatcher | GenStage.DemandDispatcher | GenStage.PartitionDispatcher
  @type stage_type         :: :consumer | :producer_consumer | :producer
  @type stage_subscription :: {atom(), min_demand: integer(), max_demand: integer()}
  @type stage_state :: %{
    stage_dispatcher:    stage_dispatcher(),
    stage_invoked_at:    integer(),
    stage_subscriptions: [stage_subscription()],
    stage_type:          atom()
  }
  
  def start_link([] = initial_state) do
    Logger.info "Start link to Job.Producer"
    GenStage.start_link __MODULE__, initial_state, name: __MODULE__
  end

  def init([] = _initial_state) do
    Logger.info "Initialise Job.Producer"
    curr_ts = DateTime.utc_now() |> DateTime.to_unix()
    subscription = [
      # Fix this using Storage.Monitor -> Storage.GCP/Storage.Local stages
      { GCP, min_demand: 0, max_demand: 1 }
    ]
    stage_state = %{ stage_invoked_at:    curr_ts,
		     stage_type:          :producer_consumer,
		     stage_subscriptions: subscription,
		     stage_dispatcher:    GenStage.DemandDispatcher }
    
    { stage_state.stage_type, stage_state,
      subscribe_to: stage_state.stage_subscriptions,
      dispatcher:   stage_state.stage_dispatcher }
  end
  
  def handle_events(events, _from, %{} = stage_state) do
    pretty_events = events |> Enum.map(& &1.uuid) |> inspect()
    Logger.info "Called Job.Producer.handle_events on #{pretty_events}"
    input_work = events |> Enum.map(& &1.work)
    Logger.info "Job.Producer received objects with the following work defined: #{inspect input_work}"
    # Fix once we've got the GCP stuff nailed down
    processed = events
    |> Enum.map(&invoke_manifest(&1, stage_state))
    { :noreply, processed, stage_state }
  end
  
  @doc """
  This is somewhat problematic semantically.

  The assumption is that we trying to match local, cached, files, but
  the field is actually a URI and it's feasible that these will point to
  network resources.

  So, we just want the table name, here!

  There are basically two forms. The first one is just a path, this
  points to a local file and will likely be the correct usage. The second
  form has the `scheme', `host' and `path' fields filled out, with `http'
  or `https' as scheme, the host being something like `marine.gov.scot',
  and the path being the actual URI on their webroot like
  `/metadata/saved/rap/job_table_sampling'.

  If we were doing this properly, what we would do instead of this is to
  check that the reassembled URI portion matches the prefix before the
  file name in question. If not, error or warn because this does not
  actually match the local declaration, and there's (very likely) no such
  resource available, given it's highly specific to the given manifest
  file.
  """
  @spec extract_uri(nil | %URI{}) :: String.t() | nil
  def extract_uri(nil), do: nil
  def extract_uri(%URI{path: path, scheme: nil, userinfo: nil,
		       host: nil,  port:   nil, query:    nil,
		       fragment: nil}), do: path
  def extract_uri(%URI{path: path}) do
    path
    |> String.trim("/")
    |> String.split("/")
    |> Enum.at(-1)
  end

  @spec extract_id(nil | RDF.IRI.t()) :: String.t() | nil
  def extract_id(nil), do: nil
  def extract_id(id) do
    id
    |> RDF.IRI.to_string()
    |> String.trim("/")
    |> String.split("/")
    |> Enum.at(-1)
  end

  @doc """
  Given a nominal URI of a resource, check that it is included in the
  uploaded data package.

  This should be rewritten when we revamp the RDF generated by
  fisdat/fisup which should also generate an input resource, rather than
  just including the file names as strings in the table description.
  """
  @spec check_resource(%URI{}, [String.t()], String.t()) :: %ResourceSpec{}
  def check_resource(nominal_uri, all_resources, base_prefix) do
    referenced_resource = extract_uri(nominal_uri)
    resource_id =
      case referenced_resource do
	nil -> RDF.BlankNode.new()
	_   -> RDF.IRI.new(base_prefix <> referenced_resource)
      end
    %ResourceSpec{
      __id__: resource_id,
      download_url: resource_id,
      base: referenced_resource,
      extant: referenced_resource in all_resources and not is_nil(referenced_resource)
    }
  end
  
  @doc """
  This function only checks the validity of the TTL conversion of LinkML
  YAML schema files, as these YAML files are not usable outside of
  LinkML, i.e. they only serve as input data, just as we don't validate
  anything about any input YAML manifest files.
  """
  @spec check_table(%TableDesc{}, [String.t()], String.t()) :: %TableSpec{}
  def check_table(%TableDesc{} = desc, resources, base_prefix) do

    source_id = desc.__id__
    new_id    = RDF.IRI.append(source_id, "_processed")
    Logger.info "Checking table #{inspect source_id}, in resources #{inspect resources}"
    
    data_validity   = check_resource(desc.resource_path,   resources, base_prefix)
    schema_validity = check_resource(desc.schema_path_ttl, resources, base_prefix)
    
    %TableSpec{ __id__:    new_id,        submitted_table: source_id,
		title:     desc.title,    description:     desc.description,
		resource:  data_validity, schema_ttl:      schema_validity }
  end

  @doc """
  With the new data structure, the table is implictly valid, so we just
  need to extract the information of interest (path to table).
  Nonetheless, may consider a possible error case where this is nil.
  This is a blank node so there's no notion of a source IRI
  """
  @spec check_column(%ScopeDesc{}) :: %ScopeSpec{}
  def check_column(%ScopeDesc{column:   column,
                              variable: underlying,
                              table: %RAP.Manifest.TableDesc{
				        __id__:        table_id,
					resource_path: resource_uri
                              }}) do
    # Don't sub in the table yet, it is primarily relevant when SERIALISING
    # we already got the resource name/base out of the injected struct
    # Let's see if this breaks ought
    # For the variable, the only reason we extract the ID is it gets read
    # as this ExtColumnDesc, this is fixable. After that, the only difference
    # between ScopeSpec and ScopeDesc is we have the temporary annotated fields
    # below
    %ScopeSpec{
      __id__:         RDF.BlankNode.new(), # clever!
      column:         column,
      variable_id:    underlying.__id__,
      variable_curie: underlying.compact_uri,
      resource_name:  extract_id(table_id),
      resource_base:  extract_uri(resource_uri) 
      #, table_id:       table_id 
    }
  end

 @doc """
  This is largely the same as the column-level errors. The main thing
  which we want to do is to preserve both the error columns and the non-
  error columns, and to be able to warn, or issue errors which highlight
  any errors *which are applicable*.
 """
 @spec check_job(%JobDesc{}, [any()]) :: %JobSpec{}
  def check_job(%JobDesc{} = desc, _tables) do
    sub = fn(%ScopeSpec{variable_curie: var0}, %ScopeSpec{variable_curie: var1}) ->
     var0 < var1
    end
    source_id = desc.__id__
    new_id    = RDF.IRI.append(source_id, "_processed")
    scope_descriptive = desc.job_scope_descriptive |> Enum.map(&check_column/1) |> Enum.sort(sub)
    scope_collected   = desc.job_scope_collected   |> Enum.map(&check_column/1) |> Enum.sort(sub)
    scope_modelled    = desc.job_scope_modelled    |> Enum.map(&check_column/1) |> Enum.sort(sub)

    generated_job = %JobSpec{
      __id__:            new_id,
      submitted_job:     source_id,
      type:              desc.job_type,
      result_format:     desc.job_result_format,
      result_stem:       desc.job_result_stem,
      title:             desc.title,
      description:       desc.description,
      scope_descriptive: Enum.sort(scope_descriptive, sub),
      scope_collected:   Enum.sort(scope_collected, sub),
      scope_modelled:    Enum.sort(scope_modelled, sub)
    }
    Logger.info "Generated job: #{inspect generated_job}"
    generated_job
  end

  # Don't check gcp_source for now, it's not in any generated RDF graphs
  @doc """
  Check the injected manifest against the previous stage
  """
  @spec check_manifest(%ManifestDesc{}, %MidRun{}, atom(), integer(), stage_state()) :: {:ok, %ManifestSpec{}} | {:error, atom()} | {:error, atom(), [%TableDesc{}]}
  def check_manifest(%ManifestDesc{ description:   nil, title: nil,
				    tables:        [],  jobs:  [],
				    local_version: nil},
                     _prev, _signal, _work_start, _stage_state) do
    {:error, :empty_manifest}
  end
  def check_manifest(%ManifestDesc{} = desc, %MidRun{manifest_iri: source_id} = prev, curr_signal, work_started_at, %{} = stage_state) do
    Logger.info "Check manifest #{source_id} (title #{inspect desc.title})"
    Logger.info "Working on tables: #{inspect desc.tables}"
    Logger.info "Working on jobs: #{inspect desc.jobs}"
    
    test_extant = fn tab ->
      res = tab.resource
      sch = tab.schema_ttl
      res.extant and sch.extant
    end
    
    processed_tables  = desc.tables |> Enum.map(&check_table(&1, prev.resources, prev.base_prefix))
    extant_tables     = processed_tables |> Enum.filter(test_extant)
    non_extant_tables = processed_tables |> Enum.reject(test_extant)

    Logger.info "Processed tables: #{inspect processed_tables}"
    Logger.info "Actually extant tables: #{inspect extant_tables}"
    
    if length(processed_tables) != length(extant_tables) do
	{:error, :bad_tables, non_extant_tables}
    else
      processed_jobs = desc.jobs |> Enum.map(&check_job(&1, extant_tables))
      new_id   = RDF.IRI.append(source_id, "_processed")
      new_work = Work.append_work(prev.work, __MODULE__, curr_signal, work_started_at, stage_state)
      manifest_obj = %ManifestSpec{
	__id__:             new_id,
	submitted_manifest: source_id,
	title:              desc.title,
	description:        desc.description,
	local_version:      desc.local_version,
	uuid:               prev.uuid,
	data_source:        prev.data_source,
	signal:             curr_signal,
	work:               new_work,
	submitted_manifest_base_ttl:  prev.manifest_ttl,
	submitted_manifest_base_yaml: prev.manifest_yaml,
	resource_bases:     prev.resources,
	tables:             processed_tables,
	jobs:               processed_jobs,
	base_prefix:        prev.base_prefix
      }
      {:ok, manifest_obj}
    end
  end

  @spec minimal_manifest(%MidRun{}, atom(), integer(), stage_state()) :: %ManifestSpec{}
  def minimal_manifest(%MidRun{} = prev, curr_signal, work_started_at, %{} = stage_state) do
    source_id = prev.manifest_iri
    new_id    = RDF.IRI.append(source_id, "_processed")
    new_work  = Work.append_work(prev.work, __MODULE__, curr_signal, work_started_at, stage_state)
    %ManifestSpec{ __id__:             new_id,
		   uuid:               prev.uuid,
		   data_source:        prev.data_source,
		   signal:             curr_signal,
		   work:               new_work,
		   submitted_manifest_base_ttl:  prev.manifest_ttl,
		   submitted_manifest_base_yaml: prev.manifest_yaml,
		   resource_bases:     prev.resources,
		   submitted_manifest: source_id,
		   base_prefix:        prev.base_prefix }
  end

  @doc """
  Invoke manifest based on signal from previous stage `RAP.Storage.GCP'.

  The function which produces the `%GCP{}' struct passed on to this stage
  is `RAP.Storage.GCP.coalesce_job/3'.

  This function does the following:
  1. Fetch the index file `.index';
  2. Read the file
  3. Extract name of the YAML manifest and TTL conversion
  
  In any case, if the function does not complete, the only thing we know
  about the job is the UUID. This is annotated with the signal.
  That is, if the signal is not the atom `:working', then we have no
  access to the file name of the two manifest files.

  Therefore pattern match on that signal and pass it up.

  In the following function `invoke_manifest/3', the :working signal
  indicates that not only was `coalesce_job/3' successful, but we were
  able to extract an RDF graph from it. If we weren't, then we wouldn't
  be able to know anything about the resources and can't run any jobs,
  because these are described by the RDF graph. We won't know the base
  prefix either, so fall back to some sensible base prefix, from which
  the result reporting this error can be served.

  There are three signals of interest here which we can pattern-match on.
  1. The `:empty_manifest' signal implies that the manifest in question
     could not be loaded by Grax. Any other error tuple with two fields
     arises from `RDF.Turtle.read_file/1', since our `check_manifest/5'
     function either returns {:ok, <manifest object>} or
     {:error, :bad_tables, <tables>}.
  2. The `:bad_input_graph' signal implies that the manifest in question
     has a duff RDF graph. This usually arises in terms of cardinality,
     i.e. mandatory fields are of length zero.
  3. The `:bad_manifest_tables' signal implies that the manifest in
     question is a valid RDF graph, but that the specified tables are
     duff in some way.

  It is possible that the :bad_manifest_tables signal is something which
  we can use, but it also implies that no jobs should be run, so don't
  try to run these, at least for now. Only pattern-match on `:working'.
  """
  @spec invoke_manifest(%MidRun{}, stage_state()) :: %ManifestSpec{} | {:error, atom()} | {:error, atom(), [%TableDesc{}]}
  def invoke_manifest(%MidRun{signal: :working} = prev, %{} = stage_state) do
    cache_dir          = Application.fetch_env!(:rap, :cache_directory) 
    target_dir         = "#{cache_dir}/#{prev.uuid}"
    manifest_full_path = "#{target_dir}/#{prev.manifest_ttl}"
    load_target        = RDF.iri(prev.manifest_iri)
    work_started_at    = DateTime.utc_now() |> DateTime.to_unix()
    
    #load_target = RAP.Vocabulary.RAP.RootManifest
    Logger.info "Building RDF graph from turtle manifest #{load_target} using data in #{target_dir}"
    with {:ok, rdf_graph}    <- RDF.Turtle.read_file(manifest_full_path),
         {:ok, ex_struct}    <- Grax.load(rdf_graph, load_target, ManifestDesc),
         {:ok, manifest_obj} <- check_manifest(ex_struct, prev, :working, work_started_at, stage_state)
      do
        Logger.info "Detecting feasible jobs"
	Logger.info "Found RDF graph:"
	Logger.info "#{inspect rdf_graph}"
	Logger.info "Corresponding struct to RDF graph:"
	Logger.info "#{inspect ex_struct}"
	Logger.info "Processed/annotated manifest:"
	Logger.info "#{inspect manifest_obj}"
	manifest_obj
    else
      {:error, :empty_manifest} ->
	Logger.info "Corresponding struct to RDF graph was empty!"
	minimal_manifest(prev, :empty_manifest, work_started_at, stage_state)
      {:error, err} ->
	Logger.info "Could not read RDF graph #{manifest_full_path}"
        Logger.info "Error was #{inspect err}"
	minimal_manifest(prev, :bad_input_graph, work_started_at, stage_state)
      {:error, :bad_tables, _tables} ->
	Logger.info "Error arising from manifest object shape"
	minimal_manifest(prev, :bad_manifest_tables, work_started_at, stage_state)
    end
  end
  def invoke_manifest(%MidRun{} = prev, %{} = stage_state) do
    # We already have a notion of a well-known unique identifier (UUID),
    # so use it as fallback
    fallback_base = RAP.Vocabulary.RAP.__base_iri__
    target_id = RDF.IRI.new("#{fallback_base}RootManifest#{prev.uuid}_processed")

    work_started_at = DateTime.utc_now() |> DateTime.to_unix()
    new_work = Work.append_work(prev.work, __MODULE__, :see_pre, work_started_at, stage_state)
    
    %ManifestSpec{
      __id__:          target_id,
      uuid:            prev.uuid,
      data_source:     prev.data_source,
      base_prefix:     fallback_base,
      submitted_manifest_base_ttl:  prev.manifest_ttl,
      submitted_manifest_base_yaml: prev.manifest_yaml,
      resource_bases: prev.resources,
      signal:          :see_pre,
      work:            new_work
    }
  end
  
end
