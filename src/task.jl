using Distributed, Statistics, Logging, UUIDs, HTTP
using LinearAlgebra: eigvals

const DEFAULT_SHOTS = 1000
const DEFAULT_RESULTS_POLL_TIMEOUT = 432000
const DEFAULT_RESULTS_POLL_INTERVAL = 1

"""
    AwsQuantumTask

Struct representing a task run on an Amazon-managed device.
"""
mutable struct AwsQuantumTask
    arn::String 
    client_token::String
    poll_timeout_seconds::Int
    poll_interval_seconds::Int
    _future::Union{Future, Nothing}
    _metadata::Dict{String, Any}
    _logger::AbstractLogger
    _result::Union{Nothing, AbstractQuantumTaskResult}
    function AwsQuantumTask(arn::String;
                   client_token::String=string(uuid1()),
                   poll_timeout_seconds::Int=DEFAULT_RESULTS_POLL_TIMEOUT,
                   poll_interval_seconds::Int=DEFAULT_RESULTS_POLL_INTERVAL,
                   logger=global_logger())
        new(arn, client_token, poll_timeout_seconds, poll_interval_seconds, nothing, Dict(), logger, nothing)
    end
end
Base.show(io::IO, t::AwsQuantumTask) = println(io, "AwsQuantumTask(\"id/taskArn\":\"$(arn(t))\")")
id(t::AwsQuantumTask) = t.arn
"""
    arn(t::AwsQuantumTask) -> String

Returns the ARN identifying the task `t`. This ARN can be used to 
reconstruct the task after the session that launched it has exited.
"""
arn(t::AwsQuantumTask) = t.arn

function AwsQuantumTask(args::NamedTuple)
    action       = args[:action]
    client_token = args[:client_token]
    device_arn   = args[:device_arn]
    s3_bucket    = args[:outputS3Bucket]
    s3_key_prefix = args[:outputS3KeyPrefix]
    shots        = args[:shots]
    extra_opts   = args[:extra_opts]
    job_token    = get(ENV, "AMZN_BRAKET_JOB_TOKEN", nothing)
    !isnothing(job_token) && merge!(extra_opts, Dict("jobToken"=>job_token))
    timeout_seconds  = get(args, :poll_timeout_seconds, DEFAULT_RESULTS_POLL_TIMEOUT)
    interval_seconds = get(args, :poll_interval_seconds, DEFAULT_RESULTS_POLL_INTERVAL)
    merge!(AWS.AWSServices.braket.service_specific_headers, AWS.LittleDict("Braket-Trackers"=>string(length(GlobalTrackerContext[]))))
    response         = BRAKET.create_quantum_task(action, client_token, device_arn, s3_bucket, s3_key_prefix, shots, extra_opts)
    pop!(AWS.AWSServices.braket.service_specific_headers, "Braket-Trackers")
    broadcast_event!(TaskCreationEvent(response["quantumTaskArn"], shots, !isnothing(job_token), device_arn))
    return AwsQuantumTask(response["quantumTaskArn"]; client_token=client_token, poll_timeout_seconds=timeout_seconds, poll_interval_seconds=interval_seconds)
end

function default_task_bucket()
    haskey(ENV, "AMZN_BRAKET_TASK_RESULTS_S3_URI") && return parse_s3_uri(ENV["AMZN_BRAKET_TASK_RESULTS_S3_URI"])
    return (default_bucket(), "tasks")
end

"""
    AwsQuantumTask(device_arn::String, task_spec; kwargs...)

Launches an [`AwsQuantumTask`](@ref) based on `task_spec` on the device associated with `device_arn`.

`task_spec` must be one of:
  - `OpenQASMProgram`
  - `BlackbirdProgram`
  - `Problem`
  - `Program`
  - [`Circuit`](@ref)
  - `AHSProgram`
  - [`AnalogHamiltonianSimulation`](@ref)

Valid `kwargs` are:
  - `s3_destination_folder::Tuple{String, String}`, with default value `default_task_bucket()`.
  - `shots::Int` - the number of shots to run, with default value $DEFAULT_SHOTS. Value must be between `0` and `MAX_SHOTS` for the specific device.
  - `device_params::Dict{String, Any}` - device specific parameters. Currently only used for DWave devices and simulators.
  - `disable_qubit_rewiring::Bool` - whether to allow qubit rewiring in the compilation stage. Default is `false`.
  - `poll_timeout_seconds::Int` - maximum number of seconds to wait while polling for results. Default: $DEFAULT_RESULTS_POLL_TIMEOUT
  - `poll_interval_seconds::Int` - default number of seconds to wait between attempts while polling for results. Default: $DEFAULT_RESULTS_POLL_INTERVAL
  - `tags::Dict{String, String}` - tags for the `AwsQuantumTask`
"""
function AwsQuantumTask(device_arn::String,
                        task_spec::Union{AbstractProgram, Circuit, AnalogHamiltonianSimulation};
                        s3_destination_folder::Tuple{String, String}=default_task_bucket(),
                        shots::Int=DEFAULT_SHOTS,
                        device_params::Dict{String, Any}=Dict{String,Any}(),
                        disable_qubit_rewiring::Bool=false,
                        poll_timeout_seconds::Int=DEFAULT_RESULTS_POLL_TIMEOUT,
                        poll_interval_seconds::Int=DEFAULT_RESULTS_POLL_INTERVAL,
                        tags::Dict{String, String}=Dict{String, String}())
    args = prepare_task_input(task_spec, device_arn, s3_destination_folder, shots, device_params, disable_qubit_rewiring, tags=tags, poll_timeout_seconds=poll_timeout_seconds, poll_interval_seconds=poll_interval_seconds)
    return AwsQuantumTask(args)
end

function _create_annealing_device_params(device_params::Dict{Symbol, Any}, device_arn::String)
    if occursin("Advantage", device_arn)
        T = DwaveAdvantageDeviceParameters
        TL = DwaveAdvantageDeviceLevelParameters
    elseif occursin("2000Q", device_arn)
        T = Dwave2000QDeviceParameters
        TL = Dwave2000QDeviceLevelParameters
    else
        throw(ArgumentError("Amazon Braket could not find a device with the ARN: $device_arn. To continue, make sure that the value of the device_arn parameter corresponds to a valid QPU."))
    end
    device_level_parameters = haskey(device_params, :deviceLevelParameters) ? convert(Dict{Symbol, Any}, device_params[:deviceLevelParameters]) : convert(Dict{Symbol, Any}, get(device_params, :providerLevelParameters, Dict{Symbol, Any}()))
    device_level_parameters = delete!(device_level_parameters, :braketSchemaHeader) # in case of old version
    defaults = merge(Dict(zip(fieldnames(TL), fill(nothing, nfields(TL)))), StructTypes.defaults(TL))
    sym_dlps = Dict(zip(Symbol.(keys(device_level_parameters)), values(device_level_parameters)))
    dlps     = merge(defaults, sym_dlps)
    dlps[:braketSchemaHeader] = Braket.header_dict[TL]
    device_level_parameters = StructTypes.constructfrom(TL, dlps)
    return T(Braket.header_dict[T], device_level_parameters) 
end
_create_annealing_device_params(device_params, device_arn) = _create_annealing_device_params(convert(Dict{Symbol, Any}, JSON3.read(JSON3.write(device_params))), device_arn)

function _create_common_params(device_arn::String, s3_destination_folder::Tuple{String, String}, shots::Int; kwargs...)
    timeout_seconds  = get(kwargs, :poll_timeout_seconds, DEFAULT_RESULTS_POLL_TIMEOUT)
    interval_seconds = get(kwargs, :poll_interval_seconds, DEFAULT_RESULTS_POLL_INTERVAL)
    return (device_arn=device_arn, outputS3Bucket=s3_destination_folder[1],  outputS3KeyPrefix=s3_destination_folder[2], shots=shots, poll_timeout_seconds=timeout_seconds, poll_interval_seconds=interval_seconds)
end

function prepare_task_input(problem::Problem, device_arn::String, s3_folder::Tuple{String, String}, shots::Int, device_params::Union{Dict{String, Any}, DwaveDeviceParameters, DwaveAdvantageDeviceParameters, Dwave2000QDeviceParameters}, disable_qubit_rewiring::Bool=false; kwargs...)
    device_parameters = _create_annealing_device_params(device_params, device_arn)
    common = _create_common_params(device_arn, s3_folder, shots; kwargs...)
    client_token = string(uuid1())
    action     = JSON3.write(problem)
    dev_params = JSON3.write(device_parameters)
    tags       = get(kwargs, :tags, Dict{String,String}())
    extra_opts = Dict("deviceParameters"=>dev_params, "tags"=>tags)
    return merge((action=action, client_token=client_token, extra_opts=extra_opts), common)
end

function prepare_task_input(ahs::AnalogHamiltonianSimulation, device_arn::String, s3_folder::Tuple{String, String}, shots::Int, device_params::Dict{String, Any}, disable_qubit_rewiring::Bool=false; kwargs...)
    return prepare_task_input(ir(ahs), device_arn, s3_folder, shots, device_params, disable_qubit_rewiring; kwargs...)
end

function prepare_task_input(program::Union{AHSProgram, BlackbirdProgram, OpenQasmProgram}, device_arn::String, s3_folder::Tuple{String, String}, shots::Int, device_params::Dict{String, Any}, disable_qubit_rewiring::Bool=false; kwargs...)
    device_parameters = Dict{String, Any}() # not currently used
    common = _create_common_params(device_arn, s3_folder, shots; kwargs...)
    client_token = string(uuid1())
    action     = JSON3.write(program)
    dev_params = JSON3.write(device_parameters)
    tags       = get(kwargs, :tags, Dict{String,String}())
    extra_opts = Dict("deviceParameters"=>dev_params, "tags"=>tags)
    return merge((action=action, client_token=client_token, extra_opts=extra_opts), common)
end

function prepare_task_input(circuit::Union{Program, Circuit}, device_arn::String, s3_folder::Tuple{String, String}, shots::Int, device_params::Dict{String, Any}, disable_qubit_rewiring::Bool=false; kwargs...)
    validate_circuit_and_shots(circuit, shots)
    common = _create_common_params(device_arn, s3_folder, shots; kwargs...)
    paradigm_parameters = GateModelParameters(header_dict[GateModelParameters], qubit_count(circuit), disable_qubit_rewiring)
    T = GateModelSimulatorDeviceParameters # default to use simulator
    if occursin("ionq", device_arn)
        T = IonqDeviceParameters
    elseif occursin("rigetti", device_arn)
        T = RigettiDeviceParameters
    elseif occursin("oqc", device_arn)
        T = OqcDeviceParameters
    end
    device_parameters = T(header_dict[T], paradigm_parameters)
    client_token = string(uuid1())
    action       = ir(circuit)
    dev_params   = JSON3.write(device_parameters)
    tags         = get(kwargs, :tags, Dict{String,String}())
    extra_opts   = Dict("deviceParameters"=>dev_params, "tags"=>tags)
    return merge((action=action, client_token=client_token, extra_opts=extra_opts), common)
end

"""
    cancel(t::AwsQuantumTask)

Cancels the task `t`.
"""
function cancel(t::AwsQuantumTask)
    #!isnothing(t._future) && cancel(t.future)
    resp = BRAKET.cancel_quantum_task(t.client_token, t.arn)
    broadcast_event!(TaskStatusEvent(t.arn, resp["cancellationStatus"]))
    return
end

"""
    metadata(t::AwsQuantumTask, ::Val{false})
    metadata(t::AwsQuantumTask, ::Val{true})

Fetch metadata for task `t`.
If the second argument is `::Val{true}`, use previously cached
metadata, if available, otherwise fetch it from the Braket service.
If the second argument is `::Val{false}`, do not use previously cached
metadata, and fetch fresh metadata from the Braket service.
"""
function metadata(t::AwsQuantumTask, ::Val{false})
    payload = BRAKET.get_quantum_task(HTTP.escapeuri(t.arn))
    resp = Dict(zip(keys(payload), values(payload)))
    broadcast_event!(TaskStatusEvent(t.arn, resp["status"]))
    return resp
end
metadata(t::AwsQuantumTask, ::Val{true})  = !isempty(t._metadata) ? t._metadata : metadata(t, Val(false))

"""
    state(t::AwsQuantumTask, ::Val{false}) -> String
    state(t::AwsQuantumTask, ::Val{true}) -> String
    state(t::AwsQuantumTask) -> String

Fetch the state for task `t`.
Possible states are `"CANCELLED"`, `"FAILED"`, `"COMPLETED"`, `"QUEUED"`, and `"RUNNING"`.
If the second argument is `::Val{true}`, use previously cached
metadata, if available, otherwise fetch it from the Braket service.
If the second argument is `::Val{false}` (default), do not use previously cached
metadata, and fetch fresh metadata from the Braket service.
"""
function state(t::AwsQuantumTask, ::Val{false})
    mtd = metadata(t, Val(false))
    status = mtd["status"]
    if status ∈ ["FAILED", "CANCELLED"]
        with_logger(t._logger) do
            @warn "Task is in terminal state $status and no result is available."
            if status == "FAILED"
                failure_reason = get(mtd, "failureReason", "unknown")
                @warn "Task failure reason is: $failure_reason."
            end
        end
    end
    return status
end

function state(t::AwsQuantumTask, ::Val{true})
    mtd = metadata(t, Val(true))
    status = mtd["status"]
    return status
end

state(t::AwsQuantumTask) = state(t, Val(false))

"""
    result(t::AwsQuantumTask)

Fetches the result of task `t`, if available. Blocks until a result
is available, in which case the result is returned, or the task enters a
terminal state without a result (`"FAILED"` or `"CANCELLED"`) or exceeds its
its polling timeout (set at task creation), in which case `nothing` is returned.
"""
function result(t::AwsQuantumTask)
    if !isnothing(t._result) || (!isempty(t._metadata) && state(t, Val(true)) ∈ ["FAILED", "CANCELLED"])
        return t._result
    end
    if !isempty(t._metadata) && state(t, Val(true)) ∈ ["COMPLETED"]
        return _download_result(t)
    end
    start = time()
    while state(t, Val(true)) ∉ ["FAILED", "CANCELLED", "COMPLETED"] && time() - start < t.poll_timeout_seconds
        sleep(t.poll_interval_seconds)
    end
    state(t, Val(false)) == "COMPLETED" && return _download_result(t)
    return nothing
end

retrieve_result_from_s3(bucket::String, location::String) = String(AWSS3.s3_get(bucket, location))

function _download_result(t::AwsQuantumTask)
    current_meta = metadata(t, Val(true))
    result_string = retrieve_result_from_s3(current_meta["outputS3Bucket"], current_meta["outputS3Directory"] * "/results.json")
    res = parse_raw_schema(result_string)
    t._result = format_result(res)
    execution_duration = nothing
    try
        execution_duration = res.additionalMetadata.simulatorMetadata.executionDuration
    catch
        @warn "execution duration not found"
    end
    broadcast_event!(TaskCompletionEvent(t.arn, state(t, Val(true)), execution_duration))
    return t._result
end

Base.:(==)(t1::AwsQuantumTask, t2::AwsQuantumTask) = (id(t1) == id(t2))
Base.hash(t::AwsQuantumTask, h::UInt) = hash(id(t), h)

function count_tasks_with_status(device_arn::String, status::Vector{String}; token=nothing)
    token_ = token
    task_count = 0
    for status_ in status
        filters = [Dict("name"=>"status", "operator"=>"EQUAL", "values"=>[status_]), Dict("name"=>"deviceArn", "operator"=>"EQUAL", "values"=>[device_arn])]
        response = BRAKET.search_quantum_tasks(filters)
        token_ = response["nextToken"]
        status_count = length(response["quantumTasks"])
        task_count += length(response["quantumTasks"])
    end
    return task_count
end
count_tasks_with_status(device_arn::String, status::String) = count_tasks_with_status(device_arn, [status])

Base.show(io::IO, r::GateModelQuantumTaskResult) = println(io, "GateModelQuantumTaskResult")
Base.show(io::IO, r::PhotonicModelQuantumTaskResult) = println(io, "PhotonicModelQuantumTaskResult")
Base.show(io::IO, r::AnnealingQuantumTaskResult) = println(io, "AnnealingQuantumTaskResult")
Base.show(io::IO, r::AnalogHamiltonianSimulationQuantumTaskResult) = println(io, "AnalogHamiltonianSimulationQuantumTaskResult")

function measurement_counts(measurements::Vector)
    bitstrings = String[]
    for j in 1:length(measurements)
        push!(bitstrings, prod(string(qi) for qi in measurements[j]))
    end
    return counter(bitstrings)
end

function measurement_probabilities(measurement_counts::Accumulator)
    shots = sum(values(measurement_counts))
    probs = Dict{String, Float64}(key=>count/shots for (key, count) in measurement_counts)
    return probs
end

function _measurements(probs::Dict{String, Float64}, shots::Int)
    measurements = []
    for (bitstring, prob) in probs
        int_list = [tryparse(Int, string(b)) for b in bitstring]
        measurement = [int_list for ii in 1:convert(Int, round(prob*shots))]
        append!(measurements, measurement)
    end
    return measurements
end

function _selected_measurements(measurements::Matrix{Int}, measured_qubits, targets)
    (isnothing(targets) || targets == measured_qubits) && return measurements
    cols = [findfirst(q->q==t, measured_qubits) for t in targets]
    return @view measurements[:, cols]
end
_selected_measurements(measurements::Vector{Vector{Int}}, measured_qubits, targets) = _selected_measurements(mapreduce(permutedims, vcat, measurements), measured_qubits, targets)

function _measurements_base_10(measurements)
    two_powers = [2^i for i in reverse(0:size(measurements)[end]-1)]
    return measurements * two_powers
end

function _calculate_for_targets(measurements, measured_qubits, observable::Observables.StandardObservable, targets::Vector{Int}, ::Val{:sample})
    measurements = _selected_measurements(measurements, measured_qubits, targets)
    return (-2.0 .* vec(measurements)) .+ 1.0
end

function _calculate_for_targets(measurements, measured_qubits, observable::Observables.TensorProduct, targets::Vector{Int}, ::Val{:sample})
    measurements = _selected_measurements(measurements, measured_qubits, targets)
    ixs = _measurements_base_10(measurements) .+ 1
    evs = eigvals(observable)
    return real.(evs[ixs])
end

function _calculate_for_targets(measurements, measured_qubits, observable::Observables.Observable, targets::Vector{Int}, ::Val{:sample})
    measurements = _selected_measurements(measurements, measured_qubits, targets)
    ixs = _measurements_base_10(measurements) .+ 1
    evs = eigvals(observable)
    return real.(evs[ixs])
end

function _calculate_for_targets(measurements, measured_qubits, observable::Observables.Observable, targets::Vector{Int}, ::Val{:variance})
    samples = _calculate_for_targets(measurements, measured_qubits, observable, targets, Val(:sample))
    return var(samples)
end

function _calculate_for_targets(measurements, measured_qubits, observable::Observables.Observable, targets::Vector{Int}, ::Val{:expectation})
    samples = _calculate_for_targets(measurements, measured_qubits, observable, targets, Val(:sample))
    return mean(samples)
end

function _calculate_for_targets(measurements, measured_qubits, observable::Observables.Observable, targets, ::Val{V}) where {V}
    return [_calculate_for_targets(measurements, measured_qubits, observable::Observables.Observable, [q], Val(V)) for q in measured_qubits]
end

function _calculate_for_targets(measurements, measured_qubits, targets, ::Val{:probability})
    _measurements = _selected_measurements(measurements, measured_qubits, targets)
    shots, num_measured_qubits = size(_measurements)
    ixs   = _measurements_base_10(_measurements)
    count = counter(ixs)
    probabilities = zeros(Float64, 2^num_measured_qubits)
    for (b, v) in count
        probabilities[b+1] = v / shots
    end
    return probabilities
end

function calculate_result_types(ir_obj, measurements, measured_qubits::Vector{Int})
    result_types = ResultTypeValue[]
    !haskey(ir_obj, "results") && return result_types
    for result_type in ir_obj["results"]
        ir_obs = get(result_type, "observable", nothing)
        rt     = StructTypes.constructfrom(AbstractProgramResult, result_type)
        obs    = isnothing(ir_obs) ? nothing : StructTypes.constructfrom(Observables.Observable, rt.observable)
        targs  = rt.targets
        typ    = result_type["type"]
        if typ == "probability"
            val = _calculate_for_targets(measurements, measured_qubits, targs, Val(Symbol(typ)))
            push!(result_types, ResultTypeValue(rt, val))
        elseif typ ∈ ["sample", "expectation", "variance"]
            val = _calculate_for_targets(measurements, measured_qubits, obs, targs, Val(Symbol(typ)))
            push!(result_types, ResultTypeValue(rt, val))
        else
            throw(ErrorException("unknown result type $typ"))
        end
    end
    return result_types
end

function computational_basis_sampling(::Type{GateModelQuantumTaskResult}, r::GateModelTaskResult)
    task_mtd = r.taskMetadata
    addl_mtd = r.additionalMetadata
    if !isnothing(r.measurements)
        measurements = convert(Vector{Vector{Int}}, r.measurements)
        m_counts = measurement_counts(measurements)
        m_probs  = measurement_probabilities(m_counts)
        measurements_copied_from_device = true
        m_counts_copied_from_device = true
        m_probs_copied_from_device = true
    elseif !isnothing(r.measurementProbabilities)
        shots = task_mtd.shots
        m_probs  = r.measurementProbabilities
        measurements = _measurements(m_probs, shots)
        m_counts = measurement_counts(measurements) 
        measurements_copied_from_device = false
        m_counts_copied_from_device = false
        m_probs_copied_from_device = true
    else
        throw(ErrorException("One of `measurements` or `measurementProbabilities` must be populated in the result object."))
    end
    measured_qubits = r.measuredQubits
    if isnothing(r.resultTypes) || isempty(r.resultTypes)
        result_types = calculate_result_types(JSON3.read(JSON3.write(addl_mtd.action)), measurements, measured_qubits)
    else
        if !isempty(r.resultTypes) && !isnothing(r.resultTypes[1])
            json_ = Dict("results"=>[rt.type for rt in r.resultTypes])
            result_types = calculate_result_types(JSON3.read(JSON3.write(json_)), measurements, measured_qubits)
        else
            result_types = r.resultTypes
        end
    end
    vals = [rt.value for rt in result_types]
    return GateModelQuantumTaskResult(task_mtd, addl_mtd, result_types, vals, measurements, measured_qubits, m_counts, m_probs, measurements_copied_from_device, m_counts_copied_from_device, m_probs_copied_from_device, nothing)
end

function from_dict(::Type{GateModelQuantumTaskResult}, r::GateModelTaskResult)
    task_mtd = r.taskMetadata
    addi_mtd = r.additionalMetadata
    rts      = r.resultTypes
    #=vals     = map(rts) do rt
        !(rt.type isa IR.Amplitude) && return rt.value
        # need to fix return dict
        fixed_dict = Dict(string(k)=>complex(v[1], v[2]) for (k,v) in rt.value)
        return fixed_dict
    end=#
    vals = [rt.value for rt in rts]
    return GateModelQuantumTaskResult(task_mtd, addi_mtd, rts, vals, nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing)
end

function format_result(r::GateModelTaskResult)
    if r.taskMetadata.shots > 0
        return computational_basis_sampling(GateModelQuantumTaskResult, r)
    else
        return from_dict(GateModelQuantumTaskResult, r)
    end
end

function format_result(r::AnnealingTaskResult)
    solutions = convert(Vector{Vector{Int}}, r.solutions)
    values    = convert(Vector{Float64}, r.values)
    solution_counts = isnothing(r.solutionCounts) ? ones(Int, length(solutions)) : convert(Vector{Int}, r.solutionCounts)
    n_solutions = length(solutions)
    n_variables = length(solutions[1])
    record_array = AxisArray(hcat(solutions, values, solution_counts), 1:n_solutions, [:solution, :value, :solution_count])
    problem_type = JSON3.read("\"$(r.additionalMetadata.action.type)\"", ProblemType)
    return AnnealingQuantumTaskResult(record_array, n_variables, problem_type, r.taskMetadata, r.additionalMetadata) 
end

function format_result(r::PhotonicModelTaskResult)
    task_mtd = r.taskMetadata
    addi_mtd = r.additionalMetadata
    measurements = !isnothing(r.measurements) ? convert(Vector{Vector{Vector{Int}}}, r.measurements) : nothing
    return PhotonicModelQuantumTaskResult(task_mtd, addi_mtd, measurements)
end

function get_measurements(r::AnalogHamiltonianSimulationTaskResult)
    meas = map(r.measurements) do m
        status = AnalogHamiltonianSimulationShotStatusDict[lowercase(m.shotMetadata.shotStatus)]
        pre_sequence = !isnothing(m.shotResult.preSequence) ? convert(Array{Int}, m.shotResult.preSequence) : nothing
        post_sequence = !isnothing(m.shotResult.postSequence) ? convert(Array{Int}, m.shotResult.postSequence) : nothing
        return ShotResult(status, pre_sequence, post_sequence)
    end
    return meas
end

function format_result(r::AnalogHamiltonianSimulationTaskResult)
    isnothing(r.measurements) && return AnalogHamiltonianSimulationQuantumTaskResult(r.taskMetadata, nothing)
    return AnalogHamiltonianSimulationQuantumTaskResult(r.taskMetadata, get_measurements(r))
end
