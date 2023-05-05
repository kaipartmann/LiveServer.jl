module LiveServer

import Sockets, Pkg, MIMEs
using Base.Filesystem

using HTTP

export serve, servedocs

#
# Environment variables
#

#
# TODO
#
# -- banner should have an id attached to the page so that it doesn't leak
# -- refresh on initial display
# -- check paths adding and removing files do the correct triggers as per
# -- check that the fact that set_deleted only is applied if mtime > -Inf doesnt
#   cause the fix for #160 to fail.
#


"""Script to insert on a page for live reload, see `client.html`."""
# const BROWSER_RELOAD_SCRIPT = read(joinpath(@__DIR__, "client.html"), String)
BROWSER_RELOAD_SCRIPT = """
<style>
#ls-banner-deleted {
    font-family: sans-serif;
    font-size: 1.2rem;
    padding-top: 10px;
    color: white;
    background-color: #DD8374;
    z-index: 1000;
    top:0;
    display: none;
    align-items: center;
    height: 75px;
    position: fixed;
    width: 100%;
}
</style>
<div id="ls-banner-deleted">
  <div style="width: 75%; margin: auto; text-align: center;">
    The file corresponding to the requested URL has been removed. The old content is shown below.
  </div>
</div>
<script>
var ws_liveserver_M3sp9 = new WebSocket(
        (location.protocol=="https:" ? "wss:" : "ws:") + "//" + location.host + location.pathname
    );
ws_liveserver_M3sp9.onmessage = function(msg) {
    if (msg.data === "update") {
        ws_liveserver_M3sp9.close();
        location.reload();
        sessionStorage.setItem("ls-banner-deleted", "false")
    } else if (msg.data == "removed") {
        ws_liveserver_M3sp9.close();
        location.reload();
        sessionStorage.setItem("ls-banner-deleted", "true")
    };
    
};
if (sessionStorage.getItem("ls-banner-deleted") === "true") {
    document.getElementById("ls-banner-deleted").style.display = "flex"
};
</script>
"""

"""Whether to display messages while serving or not, see [`verbose`](@ref)."""
const VERBOSE = Ref{Bool}(false)

"""Whether to display debug messages while serving"""
const DEBUG = Ref{Bool}(false)

"""The folder to watch, either the current one or a specified one (dir=...)."""
const CONTENT_DIR = Ref{String}("")

"""List of files being tracked with WebSocket connections."""
const WS_VIEWERS = Dict{String,Vector{HTTP.WebSockets.WebSocket}}()

"""Keep track of whether an interruption happened while processing a websocket."""
const WS_INTERRUPT = Base.Ref{Bool}(false)


set_content_dir(d::String) = (CONTENT_DIR[] = d;)
reset_content_dir() = set_content_dir("")
set_verbose(b::Bool) = (VERBOSE[] = b;)
set_debug(b::Bool) = (DEBUG[] = b;)

reset_ws_interrupt() = (WS_INTERRUPT[] = false)

# issue https://github.com/tlienart/Franklin.jl/issues/977
setverbose = set_verbose

#
# Functions
#

include("file_watching.jl")
include("server.jl")

include("utils.jl")

end # module
