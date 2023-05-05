"""
    WatchedFile

Struct for a file being watched containing the path to the file as well as the
time of last modification.
"""
mutable struct WatchedFile{T<:AbstractString}
    path::T
    mtime::Float64
end

"""
    WatchedFile(f_path)

Construct a new `WatchedFile` object around a file `f_path`.
"""
WatchedFile(f_path::AbstractString) = WatchedFile(f_path, mtime(f_path))
 

"""
    has_changed(wf::WatchedFile)

Check if a `WatchedFile` has changed. Returns -1 if the file does not exist, 0
if it does exist but has not changed, and 1 if it has changed.
"""
function has_changed(wf::WatchedFile)::Int
    if !isfile(wf.path)
        # isfile may return false for a file
        # currently being written. Wait for 0.1s
        # then retry once more:
        sleep(0.1)
        isfile(wf.path) || return -1
    end
    return Int(mtime(wf.path) > wf.mtime)
end

"""
    set_unchanged!(wf::WatchedFile)

Set the current state of a `WatchedFile` as unchanged
"""
set_unchanged!(wf::WatchedFile) = (wf.mtime = mtime(wf.path);)

"""
    set_unchanged!(wf::WatchedFile)

Set the current state of a `WatchedFile` as deleted (if it re-appears it will
immediately be marked as changed and trigger the callback).
"""
function set_deleted!(wf::WatchedFile)
    wf.mtime = -Inf;
    # send a removed message to all viewers of that file
    for (k, v) in WS_VIEWERS
        if k == wf.path
            @show "$k > sending removed"
            for vi in v
                @async begin
                    try
                        HTTP.WebSockets.send(vi, "removed")
                    catch
                    end
                end
            end
        end
    end
end


"""
    FileWatcher

Abstract Type for file watching objects such as [`SimpleWatcher`](@ref).
"""
abstract type FileWatcher end


"""
    SimpleWatcher([callback]; sleeptime::Float64=0.1) <: FileWatcher

A simple file watcher. You can specify a callback function, receiving the path
of each file that has changed as an `AbstractString`, at construction or later
by the API function [`set_callback!`](@ref).
The `sleeptime` is the time waited between two runs of the loop looking for
changed files, it is constrained to be at least 0.05s.
"""
mutable struct SimpleWatcher <: FileWatcher
    callback::Union{Nothing,Function} # callback triggered upon file change
    task::Union{Nothing,Task}         # asynchronous file-watching task
    sleeptime::Float64                # sleep before checking for file changes
    watchedfiles::Vector{WatchedFile} # list of files being watched
    status::Symbol                    # flag caught by server
end

function SimpleWatcher(
            callback::Union{Nothing,Function}=nothing;
            sleeptime::Float64=0.1
        )
    return SimpleWatcher(
        callback,
        nothing,
        max(0.05, sleeptime),
        Vector{WatchedFile}(),
        :runnable
    )
end


"""
    file_watcher_task!(w::FileWatcher)

Helper function that's spawned as an asynchronous task and checks for file
changes. This task is normally terminated upon an `InterruptException` and
shows a warning in the presence of any other exception.
"""
function file_watcher_task!(fw::FileWatcher)::Nothing
    try
        while true
            sleep(fw.sleeptime)

            # only check files if there's a callback to call upon changes
            fw.callback === nothing && continue

            for wf ∈ fw.watchedfiles
                state = has_changed(wf)
                if state == 1
                    # file has changed, set it unchanged and trigger callback
                    set_unchanged!(wf)
                    fw.callback(wf.path)
                elseif (state == -1) && (wf.mtime > -Inf)
                    # file has been deleted, set the mtime to -Inf so that
                    # if it re-appears then it's immediately marked as changed
                    set_deleted!(wf)
                end
            end
        end
    catch err
        fw.status = :interrupted
        # an InterruptException is the normal way for this task to end
        if !isa(err, InterruptException) && VERBOSE[]
            @error "fw error" exception=(err, catch_backtrace())
        end
    end
    return nothing
end


"""
    set_callback!(fw::FileWatcher, callback::Function)

Set or change the callback function being executed upon a file change.
Can be "hot-swapped", i.e. while the file watcher is running.
"""
function set_callback!(fw::FileWatcher, callback::Function)::Nothing
    prev_running = stop(fw)   # returns true if was running
    fw.callback  = callback
    prev_running && start(fw) # restart if it was running before
    fw.status = :runnable
    return nothing
end


"""
    is_running(fw::FileWatcher)

Checks whether the file watcher is running.
"""
is_running(fw::FileWatcher) = (fw.task !== nothing) && !istaskdone(fw.task)


"""
    start(fw::FileWatcher)

Start the file watcher and wait to make sure the task has started.
"""
function start(fw::FileWatcher)
    is_running(fw) || (fw.task = @async file_watcher_task!(fw))
    # wait until task runs to ensure reliable start (e.g. if `stop` called
    # right after start)
    while fw.task.state != :runnable
        sleep(0.01)
    end
end


"""
    stop(fw::FileWatcher)

Stop the file watcher. The list of files being watched is preserved and new
files can still be added to the file watcher using `watch_file!`. It can be
restarted with `start`. Returns a `Bool` indicating whether the watcher was
running before `stop` was called.
"""
function stop(fw::FileWatcher)::Bool
    was_running = is_running(fw)
    if was_running
        # this may fail as the task may get interrupted in between which would
        # lead to an error "schedule Task not runnable"
        try
            schedule(fw.task, InterruptException(), error=true)
        catch
        end
        # wait until sure the task is done
        while !istaskdone(fw.task)
            sleep(0.1)
        end
    end
    return was_running
end


"""
    is_watched(fw::FileWatcher, f_path::AbstractString)

Checks whether the file specified by `f_path` is being watched.
"""
function is_watched(fw::FileWatcher, f_path::AbstractString)
    return any(wf -> wf.path == f_path, fw.watchedfiles)
end


"""
    watch_file!(fw::FileWatcher, f_path::AbstractString)

Add a file to be watched for changes.
"""
function watch_file!(fw::FileWatcher, f_path::AbstractString)
    if isfile(f_path) && !is_watched(fw, f_path)
        push!(fw.watchedfiles, WatchedFile(f_path))
        if VERBOSE[]
            @info "[FileWatcher]: now watching '$f_path'"
            println()
        end
    end
end
