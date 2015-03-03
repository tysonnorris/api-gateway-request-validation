-- Decorates the error response when validation fails
--
-- Usage example:
-- # NOTE: this endpoint assumes that $validate_request_status and $validate_request_response_body is set before
-- location @handle_gateway_validation_error {
--    internal;
--    content_by_lua '
--        local ErrorDecorator = require "api-gateway.validation.validatorsHandlerErrorDecorator"
--        local decorator = ErrorDecorator:new()
--        decorator:decorateResponse(ngx.var.validate_request_status, ngx.var.validate_request_response_body)
--    ';
--}

local base = require "api-gateway.validation.base"
local cjson = require "cjson"
local debug_mode = ngx.config.debug

-- Object to map the error_codes sent by validators to real HTTP response codes.
-- When a validator fail with the given "error_code", the HTTP response code is the "http_status" associated to the "error_code"
-- The "message" associated to the "error_code" is returned as well.
local DEFAULT_RESPONSES = {
    -- redisApiKeyValidator error
        MISSING_KEY     = { http_status = 403,  error_code = 403000, message = '{"error_code":"403000","message":"Api Key is required"}', headers = { ["X-Request-Id"] = "ngx.var.requestId" }},
        INVALID_KEY     = { http_status = 403,  error_code = 403003, message = '{"error_code":"403003","message":"Api Key is invalid"}', headers = { ["X-Request-Id"] = "ngx.var.requestId" }},
        K_UNKNOWN_ERROR = { http_status = 503,  error_code = 503000, message = '{"error_code":"503000","message":"Could not validate Api Key"}', headers = { ["X-Request-Id"] = "ngx.var.requestId" }},
    --oauth errors
        MISSING_TOKEN    = { http_status = 403, error_code = 403010, message = '{"error_code":"403010","message":"Oauth token is missing."}'           , headers = { ["X-Request-Id"] = "ngx.var.requestId" }},
        INVALID_TOKEN    = { http_status = 401, error_code = 401013, message = '{"error_code":"401013","message":"Oauth token is not valid"}'          , headers = { ["X-Request-Id"] = "ngx.var.requestId" }},
        T_UNKNOWN_ERROR  = { http_status = 503, error_code = 503010, message = '{"error_code":"503010","message":"Could not validate the oauth token"}', headers = { ["X-Request-Id"] = "ngx.var.requestId" }},
        SCOPE_MISMATCH   = { http_status = 403, error_code = 403011, message = '{"error_code":"403011","message":"Scope mismatch"}', headers = { ["X-Request-Id"] = "ngx.var.requestId" }},
    -- oauth profile error
        P_MISSING_TOKEN   = { http_status = 403, error_code = 403020, message = '{"error_code":"403020","message":"Oauth token missing or invalid"}' , headers = { ["X-Request-Id"] = "ngx.var.requestId" }},
        INVALID_PROFILE   = { http_status = 403, error_code = 403023, message = '{"error_code":"403023","message":"Profile is not valid"}'           , headers = { ["X-Request-Id"] = "ngx.var.requestId" }},
        NOT_ALLOWED       = { http_status = 403, error_code = 403024, message = '{"error_code":"403024","message":"Not allowed to read the profile"}', headers = { ["X-Request-Id"] = "ngx.var.requestId" }},
        P_UNKNOWN_ERROR   = { http_status = 403, error_code = 503020, message = '{"error_code":"503020","message":"Could not read the profile"}'     , headers = { ["X-Request-Id"] = "ngx.var.requestId" }},
    -- hmacSha1SignatureValidator errors
        MISSING_SIGNATURE   = { http_status = 403,  error_code = 403030, message = '{"error_code":"403030","message":"Signature is missing"}'        , headers = { ["X-Request-Id"] = "ngx.var.requestId" }},
        INVALID_SIGNATURE   = { http_status = 403,  error_code = 403033, message = '{"error_code":"403033","message":"Signature is invalid"}'        , headers = { ["X-Request-Id"] = "ngx.var.requestId" }},
        UNKNOWN_ERROR       = { http_status = 503,  error_code = 503030, message = '{"error_code":"503030","message":"Could not validate Signature"}' , headers = { ["X-Request-Id"] = "ngx.var.requestId" }},
    -- Service limit errrors
        LIMIT_EXCEEDED          = { http_status = 429, error_code = 429001, message = '{"error_code":"429001","message":"Service usage limit reached"}'       , headers = { ["X-Request-Id"] = "ngx.var.requestId" }},
        DEV_KEY_LIMIT_EXCEEDED  = { http_status = 429, error_code = 429002, message = '{"error_code":"429002","message":"Developer key usage limit reached"}' , headers = { ["X-Request-Id"] = "ngx.var.requestId" }},
    -- App valdations
        DELAY_CLIENT_ON_REQUEST = { http_status = 503, error_code = 503071, messsage = '', headers = { ["Retry_After"] = "300s" } , headers = { ["X-Request-Id"] = "ngx.var.requestId" }},
    -- CC Link validation
        INVALID_LINK        = { http_status = 403,  error_code = 403040, message = '{"error_code":"403040","message":"Invalid link"}' , headers = { ["X-Request-Id"] = "ngx.var.requestId" }},
        LINK_NOT_FOUND      = { http_status = 404,  error_code = 404040, message = '{"error_code":"404040","message":"Link not found"}' , headers = { ["X-Request-Id"] = "ngx.var.requestId" }}
    }

local default_responses_array
local user_defined_responses

local function getResponsesTemplate()
    return user_defined_responses or default_responses_array
end

local function convertResponsesToArray( responses )
    local a = {}
    for k,v in pairs(responses) do
        if ( v.error_code ~= nil and v.http_status ~= nil ) then
            --table.insert(a, v.error_code, { http_status = v.http_status, message = v.message } )
            table.insert(a, v.error_code, v )
        end
    end
    return a
end

local ValidatorHandlerErrorDecorator = {}

function ValidatorHandlerErrorDecorator:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    default_responses_array = convertResponsesToArray(DEFAULT_RESPONSES)
    return o
end

-- decorates the response by the given response_status and response_body
function ValidatorHandlerErrorDecorator:decorateResponse( response_status, response_body )
    response_status = tonumber(response_status)

    local o = getResponsesTemplate()[response_status]
    if ( o ~= nil ) then
        ngx.status = o.http_status
        -- NOTE: assumption: for the moment if it's custom, then it's application/json
        ngx.header["Content-Type"] = "application/json"
        -- add custom headers too
        if ( o.headers ~= nil ) then
            local val, i, j
            for k,v in pairs(o.headers) do
                val = tostring(v)
                -- see if the header is a variable and replace it with ngx.var.<var_name>
                i,j = string.find(val,"ngx.var.")
                if ( i ~= nil and j ~= nil ) then
                    val = string.sub(val,j+1)
                    if ( #val > 0 ) then
                        val = ngx.var[val]
                    end
                end
                ngx.header[k] = val
            end
        end
        ngx.say(o.message)
        return
    end

    -- if no custom status code was used, assume the default one is right by trusting the validators
    if ( response_body ~= nil and #response_body > 0 and response_body ~= "nil\n" ) then
        ngx.status = response_status
        ngx.say( response_body )
        return
    end
    -- if there is no custom response form the validator just exit with the status
    ngx.exit( response_status )
end

-- hook to overwrite the DEFAULT_RESPONSES by specifying a jsonString
function ValidatorHandlerErrorDecorator:setUserDefinedResponsesFromJson( jsonString )
    if ( jsonString == nil or #jsonString < 2) then
        return
    end
    local r = assert( cjson.decode(jsonString), "Invalid user defined jsonString:" .. tostring(jsonString))
    if r ~= nil then
        user_defined_responses = r
        local user_responses = convertResponsesToArray(r)
        -- merge tables
        for k,v in pairs(default_responses_array) do
            -- merge only if user didn't overwrite the default response
            if ( user_responses[k] == nil ) then
                user_responses[k] = v
            end
        end

        user_defined_responses = user_responses
    end
end

return ValidatorHandlerErrorDecorator