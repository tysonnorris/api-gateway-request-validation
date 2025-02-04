-- Copyright (c) 2015 Adobe Systems Incorporated. All rights reserved.
--
--   Permission is hereby granted, free of charge, to any person obtaining a
--   copy of this software and associated documentation files (the "Software"),
--   to deal in the Software without restriction, including without limitation
--   the rights to use, copy, modify, merge, publish, distribute, sublicense,
--   and/or sell copies of the Software, and to permit persons to whom the
--   Software is furnished to do so, subject to the following conditions:
--
--   The above copyright notice and this permission notice shall be included in
--   all copies or substantial portions of the Software.
--
--   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
--   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
--   FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
--   DEALINGS IN THE SOFTWARE.


-- User Profile validator.
-- Use this validator to add profile properties in request variables that may be passed forward to the backend service.
-- This speeds up the process to identify who the user is so that the backend service doesn't have to worry about it.

-- Dependencies:
--   1. ngx.var.oauth_host                      - optional var
--   2. ngx.var.authtoken                       - required to be set
--   3. lua_shared_dict cachedOauthTokens 50m;  - required. The local shared dict to cache user profiles
--   4. ngx.ctx.oauth_token_expires_at          - optional. This is usually set by the oauthTokenValidator
--
-- Properties that can be set by this validator:
--  1. user_email
--  2. user_country_code
--  3. user_region
--  4. user_name
--
-- User: ddascal
-- Date: 17/12/13
-- Time: 20:54
--
-- User: ajk
-- Date: 07/02/14
-- Added the logic to check for the user country and pass it as header.
--
local BaseValidator = require "api-gateway.validation.validator"
local cjson = require "cjson"

local _M = BaseValidator:new()

local RESPONSES = {
        P_MISSING_TOKEN   = { error_code = "403020", message = "Oauth token is missing"         },
        INVALID_PROFILE   = { error_code = "403023", message = "Profile is not valid"           },
        NOT_ALLOWED       = { error_code = "403024", message = "Not allowed to read the profile"},
        P_UNKNOWN_ERROR   = { error_code = "503020", message = "Could not read the profile"     }
}
---
-- @field US - countries mapping to US region
-- @field EU - countries mapping to EU region
-- @field AP - countries mapping to AP region
--
local DEFAULT_COUNTRY_MAP = {
    US = { "US", "CA", "AI", "AG", "AR", "AW", "BS", "BB", "BZ", "BM", "BO", "BR", "KY", "CL", "CO", "CR", "DM", "DO", "EC", "SV", "FK", "GF", "GD", "GP", "GT", "GY", "HT", "HN", "JM", "MQ", "MX", "MS", "AN", "NI", "PA", "PY", "PE", "KN", "LC", "PM", "VC", "GS", "SR", "TT", "TC", "UM", "UY", "VE", "VG", "AS" },
    EU = { "GB", "AL", "DZ", "AD", "AO", "AM", "AT", "AZ", "BY", "BE", "BJ", "BA", "BW", "IO", "BG", "BF", "BI", "CM", "CV", "CF", "TD", "KM", "CD", "CG", "HR", "CY", "CZ", "DK", "DJ", "EG", "GQ", "ER", "EE", "ET", "FO", "FI", "FR", "GA", "GM", "GE", "DE", "GH", "GI", "GR", "GL", "GN", "GW", "HU", "IS", "IE", "IT", "CI", "KE", "LV", "LS", "LR", "LY", "LI", "LT", "LU", "MK", "MG", "MW", "ML", "MT", "MR", "MU", "YT", "MD", "MC", "ME", "MA", "MZ", "NA", "NL", "NE", "NG", "NO", "PS", "PL", "PT", "RE", "RO", "RW", "SH", "SM", "ST", "SN", "CS", "RS", "SC", "SL", "SK", "SI", "SO", "ZA", "ES", "SJ", "SZ", "SE", "CH", "TZ", "TG", "TN", "UG", "UA", "VA", "EH", "ZM", "ZW" },
    AP = { "AU", "AF", "AQ", "BH", "BD", "BT", "BN", "MM", "KH", "CN", "CX", "CC", "CK", "TL", "FJ", "PF", "HK", "IN", "ID", "IQ", "IL", "JP", "JO", "KZ", "KI", "KR", "KW", "KG", "LA", "LB", "MO", "MY", "MV", "MH", "FM", "MN", "NR", "NP", "NC", "NZ", "NU", "NF", "OM", "PK", "PG", "PH", "PN", "QA", "RU", "WS", "SA", "SG", "SB", "LK", "TW", "TJ", "TH", "TK", "TO", "TR", "TM", "TV", "AE", "UZ", "VU", "VN", "WF", "YE" }
}

---
-- Maximum time in seconds specifying how long to cache a valid token in GW's memory
local LOCAL_CACHE_TTL = 60

-- returns the key that should be used when looking up in the cache --
function _M:getCacheToken(token)
    local t = token;
    local oauth_host = ngx.var.oauth_host
    if (oauth_host) then
        return "cachedoauth:" .. t .. ":" .. oauth_host;
    else
        return "cachedoauth:" .. t;
    end
end

--- Converts the expire_at into expire_in in seconds
-- @param expire_at UTC expiration time in seconds
--
function _M:getExpiresIn(expire_at)
    if ( expire_at == nil ) then
        return LOCAL_CACHE_TTL
    end

    local expire_at_s = expire_at
    if expire_at_s > 9999999999 then
        expire_at_s = expire_at / 1000
    end

    local local_t = ngx.time() -- os.time()
    local expires_in_s = expire_at_s - local_t
    return expires_in_s
end

function _M:getContextPropertiesObject(obj)
    local props = {}
    for k, v in pairs(obj) do
        if v ~= nil then
            props[k] = v
            if k == "user_name" or k == "user_first_name" or k == "user_last_name" then
                props[k] = ngx.escape_uri(tostring(v))
            end
        end
    end
    return props
end

function _M:getProfileFromCache(cacheLookupKey)
    local localCacheValue = self:getKeyFromLocalCache(cacheLookupKey, "cachedUserProfiles")
    if ( localCacheValue ~= nil ) then
        -- ngx.log(ngx.WARN, "Found profile in local cache")
        return localCacheValue
    end

    local redisCacheValue = self:getKeyFromRedis(cacheLookupKey, "user_json")
    if ( redisCacheValue ~= nil ) then
        ngx.log(ngx.DEBUG, "Found User Profile in Redis cache")
        local oauthTokenExpiration = ngx.ctx.oauth_token_expires_at
        local expiresIn = self:getExpiresIn(oauthTokenExpiration)
        local localExpiresIn = math.min( expiresIn, LOCAL_CACHE_TTL )
        ngx.log(ngx.DEBUG, "Storing cached User Profile in the local cache for " .. tostring(localExpiresIn) .. " s out of a total validity of " .. tostring(expiresIn) .. " s.")
        self:setKeyInLocalCache(cacheLookupKey, redisCacheValue, localExpiresIn, "cachedUserProfiles")
        return redisCacheValue
    end
    return nil;
end

function _M:storeProfileInCache(cacheLookupKey, cachingObj)
    local cachingObjString = cjson.encode(cachingObj)

    local oauthTokenExpiration = ngx.ctx.oauth_token_expires_at
    local expiresIn = self:getExpiresIn(oauthTokenExpiration)
    local localExpiresIn = math.min( expiresIn, LOCAL_CACHE_TTL )
    ngx.log(ngx.DEBUG, "Storing new cached User Profile in the local cache for " .. tostring(localExpiresIn) .. " s out of a total validity of " .. tostring(expiresIn) .. " s.")

    self:setKeyInLocalCache(cacheLookupKey, cachingObjString, localExpiresIn , "cachedUserProfiles")
    -- cache the use profile for 5 minutes
    self:setKeyInRedis(cacheLookupKey, "user_json", oauthTokenExpiration or ((ngx.time() + LOCAL_CACHE_TTL) * 1000 ), cachingObjString)
end

--- Returns true if the profile is valid for the request context
--     This method is to be overritten when this class is extended
-- @param cachedProfile The information about the user profile that gets cached
function _M:isProfileValid(cachedProfile)
    return true
end

---
--  Returns an object mapping countries to regions
function _M:getDefaultCountryMap()
    return DEFAULT_COUNTRY_MAP
end

function _M:getUserRegion( user_country_code, country_map )
    local cmap = country_map or self:getDefaultCountryMap()
    for region,countries in pairs(cmap) do
        for i , countryCode in pairs(countries) do
            if user_country_code == countryCode then
                return region
            end
        end
    end
    return "US"
end

---
-- Returns an object with a set of variables to be saved in the request's context and later in the request's vars
--  IMPORTANT: This method is only called when fetching a new profile, otherwise the information from the cache
--             is read and automatically added to the context based on the object returned by this method
-- @param profile User Profile
--
function _M:extractContextVars(profile)
    local cachingObj = {};
    cachingObj.user_email           = profile.email
    cachingObj.user_country_code    = profile.countryCode
    cachingObj.user_name            = profile.displayName
    cachingObj.user_region          = self:getUserRegion(profile.countryCode)
    cachingObj.user_first_name      = profile.first_name
    cachingObj.user_last_name       = profile.last_name
    return cachingObj
end

function _M:validateRequest()
    -- ngx.var.authtoken needs to be set before calling this method
    local oauth_token = ngx.var.authtoken
    if oauth_token == nil or oauth_token == "" then
        --return self:exitFn(ngx.HTTP_BAD_REQUEST)
        return self:exitFn(RESPONSES.P_MISSING_TOKEN.error_code, cjson.encode(RESPONSES.P_MISSING_TOKEN))
    end

    --1. try to get user's profile from the cache first ( local or redis cache )
    local oauth_token_hash = ngx.md5(oauth_token)
    local cacheLookupKey = self:getCacheToken(oauth_token_hash)
    local cachedUserProfile = self:getProfileFromCache(cacheLookupKey)

    if ( cachedUserProfile ~= nil ) then
        if (type(cachedUserProfile) == 'string') then
            cachedUserProfile = cjson.decode(cachedUserProfile)
        end
        self:setContextProperties(self:getContextPropertiesObject(cachedUserProfile))
        if ( self:isProfileValid(cachedUserProfile) == true ) then
            return self:exitFn(ngx.HTTP_OK)
        else
            return self:exitFn(RESPONSES.INVALID_PROFILE.error_code, cjson.encode(RESPONSES.INVALID_PROFILE))
        end
    end

	-- 2. get the user profile from the IMS profile
    local res = ngx.location.capture("/validate-user", { share_all_vars = true })
    if res.status == ngx.HTTP_OK then
    	local json = cjson.decode(res.body)
    	if json ~= nil then

            local cachingObj = self:extractContextVars(json)

            self:setContextProperties(self:getContextPropertiesObject(cachingObj))
            self:storeProfileInCache(cacheLookupKey, cachingObj)

            if ( self:isProfileValid(cachingObj) == true ) then
                return self:exitFn(ngx.HTTP_OK)
            else
                return self:exitFn(RESPONSES.INVALID_PROFILE.error_code, cjson.encode(RESPONSES.INVALID_PROFILE))
            end
        else
            ngx.log(ngx.WARN, "Could not decode /validate-user response:" .. tostring(res.body) )
        end
    else
        -- ngx.log(ngx.WARN, "Could not read /ims-profile. status=" .. res.status .. ".body=" .. res.body .. ". token=" .. ngx.var.authtoken)
        ngx.log(ngx.WARN, "Could not read /validate-user. status=" .. res.status .. ".body=" .. res.body )
        if ( res.status == ngx.HTTP_UNAUTHORIZED or res.status == ngx.HTTP_BAD_REQUEST ) then
            return self:exitFn(RESPONSES.NOT_ALLOWED.error_code, cjson.encode(RESPONSES.NOT_ALLOWED))
        end
    end
    --ngx.log(ngx.WARN, "Error validating Profile for Token:" .. tostring(ngx.var.authtoken))
    return self:exitFn(RESPONSES.P_UNKNOWN_ERROR.error_code, cjson.encode(RESPONSES.P_UNKNOWN_ERROR))
end

return _M