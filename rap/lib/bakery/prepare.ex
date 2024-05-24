defmodule RAP.Bakery.Prepare do
  @moduledoc """
  The 'bakery' effectively delivers an RDF data-set (manifest + schema +
  maybe the data model proper), annotated with some extras.

  In addition to the input data, then, the files output by the Bakery
  are:

  - Raw results generated by jobs;
  - Post-results processing of input data and/or results
    (e.g. descriptive statistics, visualisations);
  - A file which links the input data and schemata, the RDF manifest,
    results, and post-processing. Effectively a manifest post-results.

  In addition to the post-processing of results, if applicable, it is
  possible that we would want to include any pre-processing performed on
  data files (and potentially include the input data prior to this pre-
  processing). This would need to be built into the pipeline much earlier
  than this stage.
  
  This stage of the 'bakery' just outputs results from each job to the
  correct directory, then moves the files associated with the UUID.
  However, note the naming of the `manifest_pre_base' attribute in the
  module named struct. Subsequent stages will generate a 'post'-running
  manifest which links results &c. (see above) with the extant data
  submitted.

  Calling the cache functions here, rather than at the end of the
  pipeline, makes good sense because it is feasible that we want to be
  able to generate new HTML documentation / descriptive statistics /
  visualisations at arbitrary times, without re-running or re-submitting
  any jobs. Further, we might want to do it for certain jobs, but not
  others.
  """
  use GenStage
  require Logger

  alias RAP.Application
  alias RAP.Storage.{PreRun, PostRun}
  alias RAP.Job.{Result, Runner}
  alias RAP.Bakery.Prepare

  # Note naming of manifest_pre_base
  # Manifest signal is simple "are all the tables valid"?
  defstruct [ :uuid,
	      :title, :description,
	      :start_time, :end_time,
	      :manifest_signal,
	      :manifest_pre_base,
	      :resource_bases,
	      :result_bases,
	      :results,
	      :staged_tables,
	      :staged_jobs          ]
  
  def start_link(%Application{} = initial_state) do
    GenStage.start_link(__MODULE__, initial_state, name: __MODULE__)
  end

  def init(initial_state) do
    Logger.info "Initialised cache module `RAP.Bakery' with initial_state #{inspect initial_state}"
    subscription = [
      { Runner, min_demand: 0, max_demand: 1 }
    ]
    {:producer_consumer, initial_state, subscribe_to: subscription}
  end

  def handle_events(events, _from, %Application{} = state) do
    Logger.info "Testing storage consumer received #{inspect events}"
    processed_events = events
    |> Enum.map(&bake_data(&1, state.cache_directory, state.bakery_directory, state.linked_result_stem, state.job_result_stem))
    {:noreply, processed_events, state}
  end

  @doc """
  0. Check target UUID directory doesn't already exist like when fetching
  1. If it does exist, check that the files are identical
  2. Output results into the directory and call something related to job
  3. Move data from cache directory/UUID
  4. Remove UUID from ETS
  5. Add results to mnesia DB
  6. ?!
  """
  def bake_data(%Runner{} = processed, cache_dir, bakery_dir, _linked_stem, job_stem) do
    #source_dir = "#{cache_dir}/#{processed.uuid}"
    #target_dir = "#{bakery_dir}/#{processed.uuid}"
    Logger.info "Preparing result of job(s) associated with UUID #{processed.uuid}`"
    Logger.info "Prepare (mkdir(1) -p) #{bakery_dir}/#{processed.uuid}"
    File.mkdir_p("#{bakery_dir}/#{processed.uuid}")

    cached_job_bases = processed.results
    #|> Enum.map(&PostRun.cache_job(&1, processed.uuid))
    |> Enum.map(&write_result(&1.contents, bakery_dir, processed.uuid,
	job_stem, "json", &1.name))

    # Special case for the manifest, rename to something like
    # manifest_pre.ttl since we have a notion that we generate
    # a post-results manifest which links the results and the data
    # presented
    staging_pre = processed.manifest_base
    |> String.replace(~r"\.([a-z]+)$", "_pre.\\1")    
    pre_manifest_name = cond do
      staging_pre != processed.manifest_base -> staging_pre
      true                                   -> "manifest_pre.ttl"
    end
    moved_manifest = processed.manifest_base
    |> move_wrapper(cache_dir, bakery_dir, processed.uuid, pre_manifest_name)
    
    moved_resources = processed.resource_bases
    |> Enum.map(&move_wrapper(&1, cache_dir, bakery_dir, processed.uuid))

    # Start time and end time are calculated when caching, albeit %Prepare{} struct has these fields
    #end_time = DateTime.utc_now() |> DateTime.to_unix()
    semi_final_data = %Prepare{
      uuid:        processed.uuid,
      title:       processed.title,
      description: processed.description,
      manifest_pre_base: moved_manifest,
      resource_bases:    moved_resources,
      result_bases:      cached_job_bases,
      results:           processed.results,
      staged_tables:     processed.staging_tables,
      staged_jobs:       processed.staging_jobs
    }
    {:ok, cached_manifest} = PostRun.cache_manifest(semi_final_data)
    cached_manifest
  end
  
  @doc """
  This is called `write_result' but it should be generalised to any file
  we need to write which isn't already on disc, e.g. RDF descriptions of
  the data output.

  Check that the file does not exist and the file on disk doesn't have a
  matching checksum.

  When logging, the name of the job is in the file name, so no problem
  just printing that to the log.
  """
  def write_result(target_contents, bakery_directory, uuid, stem, extension, target_name \\ "") do
    target_base = if String.length(target_name) == 0 do
      "#{stem}.#{extension}"
    else
      "#{stem}_#{target_name}.#{extension}"
    end
    target_full = "#{bakery_directory}/#{uuid}/#{target_base}"
      
    Logger.info "Writing results file #{target_full}"
    
    with false <- File.exists?(target_full) && PreRun.dl_success?(
                    target_contents, File.read!(target_full), opts: [:input_text]),
         :ok   <- File.write(target_full, target_contents) do
      
      Logger.info "Wrote result of target #{inspect target_name} to fully-qualified path #{target_full}"
      target_base
    else
      true ->
	Logger.info "File #{target_full} already exists and matches checksum of result to be written"
	target_name
      {:error, error} ->
	Logger.info "Could not write to fully-qualified path #{target_full}: #{inspect error}"
        {:error, error}
    end
  end

  @doc """
  Wrapper for `File.mv/2' similarly to above
  
  Extra field for overring the target file, useful when renaming manifest
  to have `_pre' before the extension, since we generate a post-results
  linking manifest as well.
  """
  def move_wrapper(orig_fp, source_dir, bakery_dir, uuid) do
    move_wrapper(orig_fp, source_dir, bakery_dir, uuid, orig_fp)
  end
  def move_wrapper(orig_fp, cache_dir, bakery_dir, uuid, target_fp) do
    source_full = "#{cache_dir}/#{uuid}/#{orig_fp}"
    target_full = "#{bakery_dir}/#{uuid}/#{target_fp}"

    with false <- File.exists?(target_full),
	 :ok   <- File.cp(source_full, target_full),
	 :ok   <- File.rm(source_full) do
      Logger.info "Move file #{inspect source_full} to #{inspect target_full}"
      target_fp # Previously `fp' but this is the original file name…
    else
      true ->
	Logger.info "Target file #{inspect target_full} already existed, forcibly removing"
	File.rm(target_full)
        move_wrapper(orig_fp, cache_dir, bakery_dir, uuid, target_fp)
      error ->
	#Logger.info "Couldn't move file #{inspect fp} from cache #{inspect cache_dir} to target directory #{target_dir}"
	Logger.info "Couldn't move file #{inspect target_full} to #{target_full}"
	error
    end
  end

end
