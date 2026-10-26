package game

/*
    net_async.odin — shared types for the async submission API.
*/

Submit_Status   :: enum u8 {
    In_Flight,    // queued or actively running
    Success,      // server returned a 2xx
    Network_Err,  // could not reach server, timeout, malformed, etc
    Server_Err,   // server returned non-2xx
}

Submit_Handle   :: distinct u64
INVALID_HANDLE  :: Submit_Handle(0)

Submit_Result   :: struct {
    status      : Submit_Status,
    http_status : int,
    error       : string,
}