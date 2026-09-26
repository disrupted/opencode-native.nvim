---Annotations for the ACP harness backend. ACP is a distinct harness from the
---opencode API versions (`v1`/`v2`): `connection.protocol = 'acp'` while
---`connection.acp_protocol_version` carries ACP's own negotiated version.
---@alias OpencodeAcpProtocolVersion 1|2
---@alias OpencodeAcpToolKind 'read'|'edit'|'delete'|'move'|'search'|'execute'|'think'|'fetch'|'switch_mode'|'other'
---@alias OpencodeAcpToolStatus 'pending'|'in_progress'|'completed'|'failed'
---@alias OpencodeAcpStopReason 'end_turn'|'max_tokens'|'max_turn_requests'|'refusal'|'cancelled'
---@alias OpencodeAcpPermissionOptionKind 'allow_once'|'allow_always'|'reject_once'|'reject_always'

---@class OpencodeAcpContentBlock
---@field type string One of text|image|audio|resource_link|resource
---@field text? string
---@field data? string
---@field mimeType? string
---@field uri? string
---@field name? string
---@field resource? table

---@class OpencodeAcpPermissionOption
---@field optionId string
---@field name string
---@field kind OpencodeAcpPermissionOptionKind

---@class OpencodeAcpToolCallContent
---@field type string content|diff|terminal
---@field content? OpencodeAcpContentBlock
---@field path? string
---@field oldText? string
---@field newText? string
---@field terminalId? string

---@class OpencodeAcpToolCall
---@field toolCallId string
---@field title? string
---@field kind? OpencodeAcpToolKind
---@field status? OpencodeAcpToolStatus
---@field content? OpencodeAcpToolCallContent[]
---@field rawInput? table
---@field rawOutput? table
---@field locations? table[]

---@class OpencodeAcpSessionInfo
---@field sessionId string
---@field cwd? string
---@field title? string
---@field updatedAt? string
---@field meta? table

---@class OpencodeAcpAgentCapabilities
---@field loadSession? boolean
---@field promptCapabilities? table
---@field sessionCapabilities? {list?: boolean, delete?: boolean}

---@class OpencodeAcpInitializeResult
---@field protocolVersion number
---@field agentCapabilities? OpencodeAcpAgentCapabilities
---@field agentInfo? {name?: string, title?: string, version?: string}
---@field authMethods? table[]

---@class OpencodeAcpObservationAdapter
---@field new fun(connection: OpencodeAcpConnection, ref: table): OpencodeAcpObservation
---@field close fun(connection: OpencodeAcpConnection)
---@field route_event fun(connection: OpencodeAcpConnection, message: table)
---@field handle_request fun(connection: OpencodeAcpConnection, message: table)

---@class OpencodeAcpSurface
---@field operations OpencodeAcpOperations
---@field observation OpencodeAcpObservationAdapter

---@class OpencodeAcpHandshake
---@field version string
---@field protocol_version OpencodeAcpProtocolVersion
---@field agent_info? table
---@field capabilities? OpencodeAcpAgentCapabilities

---@class OpencodeAcpPendingPermission
---@field rpc_id integer|string
---@field session_id string
---@field options table<string, string|nil> Choice ('once'|'always'|'reject') to native optionId

---@class OpencodeAcpTransportOptions
---@field command string[]
---@field cwd? string
---@field env? table<string, string>
---@field on_request? fun(message: table)
---@field on_notification? fun(message: table)
---@field on_exit? fun(result: vim.SystemCompleted)

---@class OpencodeAcpTransport
---@field private _job vim.SystemObj|nil
---@field private _pending table<integer, Promise<any>>
---@field private _next_id integer
---@field private _buffer string
---@field private _alive boolean
---@field private _on_request? fun(message: table)
---@field private _on_notification? fun(message: table)
---@field private _on_exit? fun(result: vim.SystemCompleted)
---@field request fun(self: OpencodeAcpTransport, method: string, params?: table): Promise<any>
---@field notify fun(self: OpencodeAcpTransport, method: string, params?: table): boolean
---@field respond fun(self: OpencodeAcpTransport, id: integer|string, result: table): boolean
---@field respond_error fun(self: OpencodeAcpTransport, id: integer|string, code: integer, message: string, data?: any): boolean
---@field attach fun(self: OpencodeAcpTransport, job: vim.SystemObj)
---@field is_running fun(self: OpencodeAcpTransport): boolean
---@field pid fun(self: OpencodeAcpTransport): integer|nil
---@field close fun(self: OpencodeAcpTransport, reason?: string)

---@class OpencodeAcpOperations
---@field create_session fun(connection: OpencodeAcpConnection, location: OpencodeLocation, input?: table, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table>
---@field get_session fun(connection: OpencodeAcpConnection, session_id: string, location?: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table>
---@field list_sessions_project fun(connection: OpencodeAcpConnection, location: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table[]>
---@field list_sessions_global fun(connection: OpencodeAcpConnection, reverse_path_map?: OpencodeV2PathMap): Promise<table[]>
---@field submit fun(connection: OpencodeAcpConnection, session_id: string, input: table, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<{turn: Promise<table>}>
---@field interrupt fun(connection: OpencodeAcpConnection, session_id: string): Promise<boolean>
---@field reply_permission fun(connection: OpencodeAcpConnection, session_id: string, request_id: string, answer: {reply: 'once'|'always'|'reject'}): Promise<boolean>
---@field get_user_commands fun(connection: OpencodeAcpConnection, location?: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table<string, table>>
---@field list_commands fun(connection: OpencodeAcpConnection, location?: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table[]>
---@field list_agents fun(connection: OpencodeAcpConnection, location?: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table[]>
---@field list_primary_agents fun(connection: OpencodeAcpConnection, location?: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<string[]>
---@field list_subagents fun(connection: OpencodeAcpConnection, location?: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<string[]>
---@field list_models fun(connection: OpencodeAcpConnection, location?: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table[]>
---@field get_model_catalog fun(connection: OpencodeAcpConnection, location?: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table>
---@field get_default_model fun(connection: OpencodeAcpConnection, location?: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table|nil>
---@field get_config fun(connection: OpencodeAcpConnection, location?: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table>
---@field get_current_project fun(connection: OpencodeAcpConnection, location?: OpencodeLocation, path_map?: OpencodeV2PathMap, reverse_path_map?: OpencodeV2PathMap): Promise<table|nil>
---@field set_session_agent fun(connection: OpencodeAcpConnection, session_id: string, agent: string): Promise<boolean>
---@field set_session_model fun(connection: OpencodeAcpConnection, session_id: string, model: table): Promise<boolean>

---@class OpencodeAcpObservation: OpencodeObservation
---@field _connection OpencodeAcpConnection
---@field _acp_turn table|nil
---@field _acp_reply_by_input table<string, string>
---@field _acp_assistant_by_message table<string, table>
---@field _acp_pending_options table<string, boolean>
---@field submit fun(self: OpencodeAcpObservation, input: table, selected?: table): Promise<OpencodeSubmission>
---@field interrupt fun(self: OpencodeAcpObservation): Promise<boolean>
---@field reply_permission fun(self: OpencodeAcpObservation, request_id: string, answer: {choice: 'once'|'always'|'reject', message?: string}|string): Promise<boolean>

---@class OpencodeAcpConnection: OpencodeServer
---@field transport OpencodeAcpTransport|nil
---@field protocol 'acp'
---@field acp_protocol_version OpencodeAcpProtocolVersion
---@field capabilities OpencodeAcpAgentCapabilities
---@field agent_info? table
---@field operations OpencodeAcpOperations
---@field observations table<string, OpencodeAcpObservation>
---@field private _pending_permissions table<string, OpencodeAcpPendingPermission>
---@field private _acp_sessions table<string, table>
---@field private _acp_commands table[]

return {}
