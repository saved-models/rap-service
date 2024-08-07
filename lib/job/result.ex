defmodule RAP.Job.Result do
  @moduledoc """
  This is a bit more expansive than most of the RAP.Job.<x>Spec modules
  """
  require Logger

  use Grax.Schema, depth: +5
  alias RDF.NS.RDFS
  alias RAP.Vocabulary.{DCAT, PROV, SAVED}
  alias RAP.Job.Producer
  alias RAP.Job.{ScopeSpec, JobSpec}
  
  schema SAVED.ResultOutput do
    property :label,         RDFS.label,         type: :string
    property :job_type,      SAVED.job_type,     type: :string
    property :text_signal,   SAVED.job_signal,   type: :string
    property :download_url,  DCAT.downloadURL,   type: :iri
    property :started_at,    PROV.startedAtTime, type: :date_time
    property :ended_at,      PROV.endedAtTime,   type: :date_time

    link source_job: SAVED.source_job, type: JobSpec

    field :signal
    field :start_time_unix
    field :end_time_unix
    field :output_format
    field :output_stem
    field :contents
  end

  @spec expand_id(RDF.IRI.t(), String.t()) :: RDF.IRI.t() | {:error, String.t()}
  defp expand_id(source_job_id, base_prefix) do
    with {:ok, result_stem} <- Application.fetch_env(:rap, :result_stem) do
      source_job_name = Producer.extract_id(source_job_id)
      RDF.IRI.new(base_prefix <> result_stem <> "_" <> source_job_name)
    else
      :error -> {:error, "Cannot fetch result prefix from RAP configuration"}
    end
  end

  @doc """
  Normalises the two elements of failure:
    a) Command runs, but the exit code is non-zero;
    b) Command cannot be run at all (throw `ErlangError' with various codes,
       most commonly :enoent).
  """
  @spec cmd_wrapper(String.t(), String.t(), [String.t()]) :: {atom(), integer(), String.t()}
  def cmd_wrapper(shell, command, args) do
    cmd_result =
      try do
	System.cmd shell, [ command | args ], parallelism: true
      rescue
        erlang_error -> IO.inspect(erlang_error)
      end
    case cmd_result do
      {result, 0} ->
	Logger.info "Result.cmd_wrapper/3: Exit status was zero"
	Logger.info(inspect result)
	{:run_success, 0, result}
      {result, signal} ->
	Logger.info "Result.cmd_wrapper/3: Exit status was non-zero"
	Logger.info(inspect result)
	{:run_error, signal, result}
      %ErlangError{original: signal, reason: reason} ->
	Logger.info "Result.cmd_wrapper/3: Call to executable failed with signal #{inspect signal} and reason #{inspect reason}}"
	{:call_error, signal, reason }
      error ->
	Logger.info "Result.cmd_wrapper/3: Call to executable failed with error #{inspect error}"
	{:call_error, error, nil}
    end
  end

  @spec run_job(%JobSpec{}, String.t(), String.t()) :: %__MODULE__{} | {:error, String.t()}
  def run_job(
    %JobSpec{
      __id__:          source_job_id,
      type:            "density",
      scope_collected: [ %ScopeSpec{
			   variable_curie: "saved:lice_af_total",
			   column:         label_count,
			   resource_base:  resource_count}
			 | _ ],
      scope_modelled:  [ %ScopeSpec{
			   variable_curie: "saved:density",
			   column:         label_density,
			   resource_base:  resource_density},
			 %ScopeSpec{
			   variable_curie: "saved:time",
			   column:         label_time,
			   resource_base:  resource_time}
			 | _ ]
    } = spec, uuid, base_prefix
  ) do
    Logger.info "Running job #{inspect source_job_id} (associated with UUID #{uuid})"

    with {:ok, cache_dir}   <- Application.fetch_env(:rap, :cache_directory),
	 {:ok, python_call} <- Application.fetch_env(:rap, :python_call),
	 {:ok, time_zone}   <- Application.fetch_env(:rap, :time_zone) do

      start_ts   = DateTime.utc_now() |> DateTime.to_unix()
      started_at = DateTime.utc_now() |> DateTime.shift_zone!(time_zone)
      new_id     = expand_id(source_job_id, base_prefix)

      if resource_density != resource_time do
	end_ts   = DateTime.utc_now() |> DateTime.to_unix()
	ended_at = DateTime.utc_now() |> DateTime.shift_zone!(time_zone)
	res      = "Density and time not derived from same data file"
	%__MODULE__{ job_type:        "density",
		     signal:          :failure_prereq,
		     contents:        res,
		     start_time_unix: start_ts,
		     started_at:      started_at,
		     end_time_unix:   end_ts,
		     ended_at:        ended_at  }
      else
	file_path_count   = "#{cache_dir}/#{uuid}/#{resource_count}"
	file_path_density = "#{cache_dir}/#{uuid}/#{resource_density}"
	_file_path_time   = "#{cache_dir}/#{uuid}/#{resource_time}"

	Logger.info "Fully-qualified path for count data is #{file_path_count}"
	Logger.info "Fully-qualified path for density/time data is #{file_path_density}"

	end_ts   = DateTime.utc_now() |> DateTime.shift_zone!(time_zone)
	ended_at = DateTime.utc_now() |> DateTime.shift_zone!(time_zone)
      
	# This needs to be fixed so that it's less fragile, at least in terms of:
	# a) Python version
	# b) Guarantees about dependencies
	# We're after good reporting, and this information should certainly be part of that.
	py_result = 
 	  cmd_wrapper(python_call, "contrib/bin/density_count_ode.py", [
 	             file_path_count,   label_count,
 	             file_path_density, label_time,  label_density])
	case py_result do
	  {:run_success, _sig, py_result} ->
	    Logger.info "Call to external command/executable density_count_ode succeeded:"
	    Logger.info(inspect py_result)
 	    %__MODULE__{
	      __id__:          new_id,
	      job_type:        "density",
	      output_format:   spec.result_format,
	      output_stem:     spec.result_stem,
	      source_job:      spec.__id__,
	      start_time_unix: start_ts,
	      started_at:      started_at,
	      end_time_unix:   end_ts,
	      ended_at:        ended_at,
	      signal:          :working,
	      contents:        py_result
	    }
		   
	  {:run_error, _sig, py_result} ->
	    Logger.info "Call to external command/executable density_count_ode: non-zero exit status:"
	    Logger.info(inspect py_result)
 	    %__MODULE__{
	      __id__:          new_id,
	      job_type:        "density",
	      output_format:   spec.result_format,
	      output_stem:     spec.result_stem,
	      source_job:      spec.__id__,
	      start_time_unix: start_ts,
	      started_at:      started_at,
	      end_time_unix:   end_ts,
	      ended_at:        ended_at,
	      signal:          :job_failure,
	      contents:        py_result
	    }
	  
	  {:call_error, _py_error, py_result} ->
	    Logger.info "Call to Python interpreter failed or system is locked up"
 	    %__MODULE__{
	      __id__:          new_id,
	      job_type:        "density",
	      output_format:   spec.result_format,
	      output_stem:     spec.result_stem,
	      source_job:      spec.__id__,
	      start_time_unix: start_ts,
	      started_at:      started_at,
	      end_time_unix:   end_ts,
	      ended_at:        ended_at,
	      signal:          :python_error,
	      contents:        py_result
	    }
	end
      end
    else
      :error -> {:error, "Could not fetch keywords from RAP configuration"}
    end
  end

  def run_job(%JobSpec{__id__: id, type: "ignore"}, _uuid, base_prefix) do
    %__MODULE__{
      __id__:      expand_id(id, base_prefix),
      source_job:  id,
      job_type:    "ignore",
      signal:      :ignored,
      contents:    "Dummy/ignored job"
    }
  end

  def run_job(%JobSpec{__id__: id, type: invalid_type}, _uuid, base_prefix) do
    %__MODULE__{
      __id__:        expand_id(id, base_prefix),
      job_type:      invalid_type,
      source_job:    id,
      signal:        :bad_job_spec,
      contents:      "Unrecognised job spec"
    }
  end
  
end
