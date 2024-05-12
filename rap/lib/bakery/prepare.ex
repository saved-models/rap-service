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
    results, and post-processing.

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
  """
  use GenStage
  require Logger

  alias RAP.Application
  alias RAP.Job.{Result, Runner, Staging}
  alias RAP.Bakery.Prepare

  # Note naming of manifest_pre_base
  # The idea is that we 
  defstruct [ :uuid,
	      :title, :description,
	      :start, :end,
	      :manifest_pre_base,
	      :resource_bases,
	      :result_bases       ]
  
  def start_link(%Application{} = initial_state) do
    GenStage.start_link(__MODULE__, initial_state)
  end

  def init(initial_state) do
    Logger.info "Initialised cache module `RAP.Bakery' with initial_state #{inspect initial_state}"
    subscription = [
      { Runner, min_demand: 0, max_demand: 1 }
    ]
    {:consumer, initial_state, subscribe_to: subscription}
  end

  def handle_events(events, _from, %Application{} = state) do
    Logger.info "Testing storage consumer received #{inspect events}"
    #processed_events = events |> Enum.map(&bake_data(&1, bakery_directory))    
    {:noreply, [], state}
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
  def bake_data(%Runner{} = processed, bakery_directory, linked_result_stem) do
    uuid       = results.uuid
    target_dir = "#{bakery_directory}/#{uuid}"
    Logger.info "Preparing result of job(s) associated with UUID #{uuid}`"

    cache_start = DateTime.now() |> DateTime.to_unix()
    
    File.mkdir_p(target_dir)

    cached_job_bases = processed.staging_jobs
    |> Enum.map(&PostRun.cache_job/1)
    |> Enum.map(&write_result(&1.contents, bakery_directory, uuid,
	linked_result_stem, ".json", &1.name))
    
    [moved_manifest, moved_resources] = [manifest_base | resource_bases]
    |> Enum.map(&move_wrapper(&1, cache_dir, target_dir, uuid))

    cache_end = DateTime.now() |> DateTime.to_unix()
    
    {:ok, start_ts, end_ts} = processed
    |> PostRun.cache_manifest(cached_job_names)

    %Prepare{
      uuid:        processed.uuid,
      title:       processed.title,
      description: processed.description,
      start:       start_ts,
      end:         end_ts,
      manifest_pre_base: moved_manifest,
      resource_bases:    moved_resources,
      result_bases:      cached_job_bases
    }
  end
  
  @doc """
  This is called `write_result' but it should be generalised to any file
  we need to write which isn't already on disc, e.g. RDF descriptions of
  the data output.

  Check that the file does not exist and the file on disk doesn't have a
  matching checksum.
  """
  def write_result(target_contents, bakery_directory, uuid, stem, extension, target_name) do
    target_base = "#{stem}_#{target_name}.#{extension}"
    target_full = "#{bakery_directory}/#{uuid}/#{target_base}"

    with false <- File.exists?(target_full) && Staging.dl_success?(
                    target_contents, File.read!(target_full), opts: [:input_text]),
         :ok   <- File.write(target_contents, target_full) do
      
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
  """
  def move_wrapper(fp, cache_dir, target_dir, uuid) do
    source_full = "#{cache_dir}/#{uuid}/#{fp}"
    target_full = "#{target_dir}/#{uuid}/#{fp}"

    with false <- File.exists?(target_full),
	 :ok   <- File.cp(source_full, target_full),
	 :ok   <- File.rm(source_full) do
      Logger.info "Moved file #{inspect fp} from cache #{inspect cache_dir} to target directory #{target_dir}"
      fp
    else
      true ->
	Logger.info "Target file #{inspect target_full} already existed, forcibly removing"
	File.rm(target_full)
        move_wrapper(cache_dir, bakery_dir, uuid, fp)
      error ->
	Logger.info "Couldn't move file #{inspect fp} from cache #{inspect cache_dir} to target directory #{target_dir}"
	error
    end
  end

end
