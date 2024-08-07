defmodule RAP.Storage do
  @moduledoc """
  """
  use Amnesia
  
  defdatabase DB do
    deftable Manifest, [
      :uuid, :data_source,
      :start_time_unix, :end_time_unix,
      :submitted_manifest_base_ttl,
      :submitted_manifest_base_yaml,
      :processed_manifest_base_ttl,
      :resource_bases,
      :signal,
      :result_bases
    ] do
      @type t :: %Manifest{
	uuid: String.t(),
	data_source: atom(),
	start_time_unix: integer(),
	end_time_unix: integer(),
	submitted_manifest_base_ttl: String.t(),
	submitted_manifest_base_yaml: String.t(),
	processed_manifest_base_ttl: String.t(),
	resource_bases: [String.t()],
	signal: atom(),
	result_bases: [String.t()]
      }
    end
  end
  
end

defmodule RAP.Storage.PreRun do
  @moduledoc """
  This module largely serves to provide utility functions
  """
  require Amnesia
  require Amnesia.Helper
  require RAP.Storage.DB.Manifest, as: ManifestTable

  require Logger

  defstruct [ :uuid, :index, :resources, :signal, :work ]

  @doc """
  Simple wrapper around Erlang term storage table of UUIDs with 
  """
  @type uuid() :: String.t()
  @spec ets_feasible?(uuid()) :: boolean()
  def ets_feasible?(uuid) do
    {:ok, ets_table} = Application.fetch_env(:rap, :ets_table)
    case :ets.lookup(ets_table, uuid) do
      [] -> true
      _  ->
	Logger.info("Job UUID #{uuid} is already running, cannot add to ETS (table #{ets_table}).")
        false
    end
  end

  @doc """
  Simple helper function to compare MD5 checksums given by the storage
  objects API to the actual file downloaded.

  Erlang's `:crypto' works on a binary, not a file path, which is very
  convenient because it avoids writing to disk duff file responses.

  Further note that in `fetch_job_deps/3', sets `:decode' to false, as
  there may be a risk that the decoding breaks this workflow.
  """
  @spec dl_success?(String.t(), String.t(), [input_md5: boolean()]) :: boolean()
  def dl_success?(purported_md5, body, opts: [input_md5: true]) do
    actual_md5 = :crypto.hash(:md5, body) |> Base.encode64()
    purported_md5 == actual_md5
  end
  def dl_success?(body0, body1, opts: [input_md5: false]) do
    body0_md5 = :crypto.hash(:md5, body0) |> Base.encode64()
    body1_md5 = :crypto.hash(:md5, body1) |> Base.encode64()
    body0_md5 == body1_md5
  end
  @spec dl_success?(String.t(), String.t()) :: boolean()
  def dl_success?(purported_md5, body) do
    dl_success?(purported_md5, body, opts: [input_md5: true])
  end

  @spec mnesia_feasible?(uuid()) :: boolean()
  def mnesia_feasible?(uuid) do
    Amnesia.transaction do
      case ManifestTable.read!(uuid) do
	nil -> true
	_   ->
	  Logger.info("Found job UUID #{uuid} in job cache!")
	  false
      end
    end
  end

end

defmodule RAP.Storage.MidRun do
  @moduledoc """
  This is a generic minimal named module to describe a 'package'
  of data files, and where they are sourced from.

  The basic idea is, we have a bunch of modules which can fetch
  data from various places. Once they've actually fetched the data,
  it's stored in the local data cache, and it's got the same components.

  To make feedback richer, we can record also the source (e.g. GCP, some
  local directory we're monitoring, some other object store like S3), so
  it's clear where failures occur.
  """
  defstruct [ :uuid, :signal, :work, :data_source, :manifest_iri, :base_prefix,
	      :manifest_yaml, :manifest_ttl, :resources ]
end

defmodule RAP.Storage.PostRun do

  # Need to require Exquisite to actually use Amnesia.Selection
  require Amnesia
  require Amnesia.Helper
  require Exquisite
  require Logger
  
  require RAP.Storage.DB.Manifest, as: ManifestTable

  alias RAP.Miscellaneous, as: Misc
  alias RAP.Job.ManifestSpec

  @doc """
  Remove the UUID from ETS and add a manifest row in the Mnesia DB

  This is mostly boilerplate and the error cases should never trigger due
  to the way we set up the :uuid ETS table.

  Unlike jobs, where the time it took for the job to complete is in the
  object, the start and end time-stamps here are simply the difference
  between the initial time stamp cached in ETS and the time stamp here.

  The start and end time-stamps associated with running a job only 
  concern the running of it. Jobs may share data and draw it from
  multiple sources, so calculating the completion time-stamp for a
  given job which includes the caching or subsequent processing is not
  at all meaningful.

  In contrast, the start and end time-stamps associated with a given
  manifest must include these data, since we're interested in seeing how
  long it took end-to-end, compared to specific components.

  A further piece of context is that there is relatively little cost to
  restarting or retrying an individual job, whereas there may be
  significant cost to resumbitting the manifest, since it is often
  associated with a lot of data.

  For now, don't include much information about job successes/failures.
  We do want to keep track of these somehow, and this may be the place,
  just not quite yet.
  """
  @spec cache_manifest(%ManifestSpec{}) :: %ManifestSpec{} | {:error, :ets_no_uuid} | {:error, :ets_multiple_uuids, [{String.t(), integer()}]}
  def cache_manifest(%ManifestSpec{} = manifest) do
    Logger.info "Cache processed manifest information in mnesia DB `Manifest' table"
    with {:ok, time_zone}   <- Application.fetch_env(:rap, :time_zone),
         {:ok, ets_table}   <- Application.fetch_env(:rap, :ets_table),
	 [{uuid, start_ts}] <- :ets.lookup(ets_table, manifest.uuid),
         true               <- :ets.delete(ets_table, manifest.uuid) do

      started_at = DateTime.utc_now() |> DateTime.shift_zone!(time_zone)
      end_ts     = DateTime.utc_now() |> DateTime.to_unix()
      ended_at   = DateTime.utc_now() |> DateTime.shift_zone!(time_zone)

      annotated_manifest = %ManifestSpec{ manifest |
					  start_time_unix: start_ts,
					  started_at:      started_at,
					  end_time_unix:   end_ts,
					  ended_at:        ended_at }
      Logger.info "Annotated manifest with start/end time: #{inspect annotated_manifest}"

      #transformed_manifest = %{ annotated_manifest | __struct__: ManifestTable }
      transformed_manifest =
	%ManifestTable{
	  uuid:            uuid,
	  data_source:     manifest.data_source,
	  start_time_unix: start_ts,
	  end_time_unix:   end_ts,
	  resource_bases:  manifest.resource_bases,
	  result_bases:    manifest.result_bases,
	  signal:          manifest.signal,
	  submitted_manifest_base_ttl:  manifest.submitted_manifest_base_ttl,
	  submitted_manifest_base_yaml: manifest.submitted_manifest_base_yaml,
	  processed_manifest_base_ttl:  manifest.processed_manifest_base
	}
      Logger.info "Transformed annotated manifest into: #{inspect transformed_manifest}"
      Amnesia.transaction do
	transformed_manifest |> ManifestTable.write()
      end
      annotated_manifest
    else
      [] ->
	Logger.info "Could not find UUID in ETS!"
	{:error, :ets_no_uuid}
      [{_uuid, _start} | [_ | _]] = multiple_uuids ->
	# Note, this should never happen for our usage of ETS as
	Logger.info "Found multiple matching UUIDs in ETS!"
        {:error, :ets_multiple_uuids, multiple_uuids}
      false ->
	# Note, this should never happen if the lookup succeeded:
	Logger.info "UUID was found in ETS but could not be removed"
        {:error, :ets_no_uuid}
    end
  end

  @type uuid() :: String.t()
  @spec retrieve_manifest(uuid()) :: %ManifestSpec{}
  def retrieve_manifest(uuid) do
    Logger.info "Attempt to retrieve prepared manifest information from mnesia DB `Manifest' table"
    Amnesia.transaction do
      ManifestTable.read(uuid) |> Map.new() |> inject_manifest()
    end
  end

  defp inject_manifest(nil), do: nil
  defp inject_manifest(pre), do: %{ pre | __struct__: ManifestSpec }

  @spec yield_manifests(integer(), atom()) :: [%ManifestSpec{}] | {:error, String.t()}
  def yield_manifests(after_unix_ts \\ -1, _owner \\ :any) do
    with {:ok, time_zone}  <- Application.fetch_env(:rap, :time_zone),
         {:ok, after_time} <- DateTime.from_unix(after_unix_ts) do
      date_proper = Misc.format_time(after_time, time_zone)
      Logger.info "Retrieve all prepared manifests after #{date_proper}"
    
      Amnesia.transaction do
	ManifestTable.where(start_time_unix > after_unix_ts)
	|> Amnesia.Selection.values()
	|> Enum.map(&inject_manifest/1)
      end
    else
      :error ->
	{:error, "Could not fetch time zone keyword from RAP configuration"}
      {:error, _msg} = error ->
	error
    end
  end
  
end
