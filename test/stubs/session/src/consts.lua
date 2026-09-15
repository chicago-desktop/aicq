-- Harness stand-in for wippy.session:consts: the constants the agent dialog
-- reads, with the values of wippy/session 0.4.3.
local consts = {}

consts.PROCESS = {SESSION_ID = "wippy.session.process:session"}
consts.STATUS = {IDLE = "idle", ERROR = "error"}
consts.TOPICS = {MESSAGE = "message", ERROR = "error", FINISH_AND_EXIT = "finish_and_exit"}
consts.UPSTREAM_TYPES = {UPDATE = "update", ERROR = "error", CONTENT = "content",
    FUNCTION_CALL = "function_call", FUNCTION_ERROR = "function_error"}
consts.TOPIC_PREFIXES = {SESSION = "session:", MESSAGE = ":message:"}

function consts.get_config(): any
    return {default_host = "app:processes"}
end

return consts
