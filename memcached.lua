--[[-------------------------------------------------------------------
Copyright (c) 2010 Scott Vokes <vokes.s@gmail.com>
 
Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:
 
The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.
 
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.
--]]-------------------------------------------------------------------


local DEBUG = false
local function trace(...)
   if DEBUG then print(...) end
end

local STATS_KEYS = {
   malloc = true,
   sizes = true,
   slabs = true,
   items = true,
}

-- Dependencies
local socket = require "socket"
local async_socket = require "async_socket"
local async_tcp_connect = async_socket.async_tcp_connect
local async_tcp_receive = async_socket.async_tcp_receive
local async_tcp_send    = async_socket.async_tcp_send

local socket, string, table = socket, string, table
local assert, print, setmetatable, type, tonumber, tostring =
   assert, print, setmetatable, type, tonumber, tostring



local fmt = string.format
local Memcached = {}
local Memcached_mt = {__index = Memcached}

---(Re-)Connect to the memcached server.
function Memcached:connect()
   if self._defer then 
      local conn, err = socket.tcp()
      if not conn then return false, err end
      local ok, err = async_tcp_connect(conn, self._host, self._port, 60000, self._defer, 0)
      if not conn then
         conn:close()
         return false, err
      end
      conn:settimeout(0)
      self._s = conn
      return conn
   end

   local conn, err = socket.connect(self._host, self._port)
   if not conn then return false, err end
   self._s = conn
   return conn
end


local function init_con(self)
   local sock = self._s
   if not sock then
      local err
      sock, err = self:connect()
      if not sock then return false, err end
   end
   return sock
end


---Send a command, asynchronously.
function Memcached:send(msg)
   local sock, err = init_con(self)
   if not sock then return false, err end
   local ok, err
   if self:is_async() then
      ok, err = async_tcp_send(sock, msg, nil, nil, nil, self._defer)
   else
      ok, err = sock:send(msg)
   end
   if err == 'closed' then self._s = nil end
   return ok, err
end


---Read a response (a line of text, or spec bytes), asynchronously.
function Memcached:receive(spec)
   local sock, err = init_con(self)
   if not sock then return false, err end
   spec = spec or '*l'
   local ok, err, rest
   if self:is_async() then
      ok, err, rest = async_tcp_receive(sock, spec, nil, self._defer)
   else
      ok, err, rest = sock:receive(spec)
   end
   if err == 'closed' then self._s = nil end
   return ok, err, rest
end


---Send a command and return the response or (false, error).
function Memcached:send_recv(msg)
   local res, err = self:send(msg)
   if not res then return false, err end
   res, err = self:receive()
   if not res then return false, err end
   return res
end


---Call the defer hook, if any.
function Memcached:defer() self._defer() end


---Is the connection running asynchronously?
function Memcached:is_async() return self._defer ~= nil end

local function get_key(self, key)
   if self.on_key then return self:on_key(key) end
   return key
end

--====================
--= Storage commands =
--====================

local function store_cmd(self, cmd, key, data, exptime,
                         flags, noreply, cas_id)
   key = get_key(self, key)
   if type(data) == "number" then data = tostring(data) end
   if not key then return false, "no key"
   elseif type(data) ~= "string" then return false, "no data" end
   exptime = exptime or 0
   noreply = noreply or false

   local buf = { cmd, " ", key, " ",
                 flags or 0, " ", exptime or 0, " ",
                 #data }
   if cas_id then buf[#buf+1] = " " .. cas_id end
   if noreply then buf[#buf+1] = " noreply" end
   buf[#buf+1] = "\r\n"
   buf[#buf+1] = data
   buf[#buf+1] = "\r\n"

   if noreply then return self:send(table.concat(buf)) end
   local res, err = self:send_recv(table.concat(buf))
   return res and res == "STORED", res or false, err
end


---Set a key to a value.
-- @param key A key, which cannot have whitespace or control characters
-- and must be less than 250 chars long.
-- @param data Value to associate with the key. Must be under 1 megabyte.
-- @param exptime Optional expiration time, in seconds.
-- @param flags Optional 16-bit int to associate with the key,
-- for bit flags.
-- @param noreply Do not expect a reply, just set it.
function Memcached:set(key, data, exptime, flags, noreply)
   return store_cmd(self, "set", key, data, exptime, flags, noreply)
end


---Add a value to a non-existing key.
-- @see set
function Memcached:add(key, data, exptime, flags, noreply)
   return store_cmd(self, "add", key, data, exptime, flags, noreply)
end


---Replace a key's value.
-- @see set
function Memcached:replace(key, data, exptime, flags, noreply)
   return store_cmd(self, "replace", key, data, exptime, flags, noreply)
end


---Append to a key's value.
-- @see set
function Memcached:append(key, data, exptime, flags, noreply)
   return store_cmd(self, "append", key, data, exptime, flags, noreply)
end


---Prepend to a key's value.
-- @see set
function Memcached:prepend(key, data, exptime, flags, noreply)
   return store_cmd(self, "prepend", key, data, exptime, flags, noreply)
end


---Modify a key's value if the cas ID (from gets) is still current.
-- @see gets
-- @see set
function Memcached:cas(key, data, cas_id, flags, exptime, noreply)
   return store_cmd(self, "cas", key, data,
                    exptime, flags, noreply, cas_id)
end


--======================
--= Retrieval commands =
--======================

local function do_get(self, cmd, keys, pattern)
   local mk = {} -- map key
   local rk      -- real keys
   if type(keys) == "string" then 
      keys = { get_key(self, keys) }
   else
      rk = {}
      for i, key in ipairs(keys) do
         rk[i]       = get_key(self, key)
         mk[ rk[i] ] = key
      end
   end

   local line, err = self:send_recv(fmt("%s %s\r\n", cmd,
                                        table.concat(rk or keys, " ")))
   local res, key, flags, len, data, cas = {}
   while line ~= "END" do
      if not line then return false, err end
      key, flags, len, cas = line:match(pattern)
      if not key then return false, 'bad response:' .. line end

      data, err = self:receive(tonumber(len) + 2):sub(1, -3)
      if not data then return false, err end

      flags = tonumber(flags)
      res[ mk[key] or key ] = { data=data, flags=flags, cas=cas }
      line, err = self:receive()
   end

   if not rk then return data, flags, cas end
   return res
end


---Get value and flags for one or more keys.
-- @param keys Key or {"list", "of", "keys"}.
-- @return For one key, returns (value, flags, cas). For a list of keys,
-- returns a { key1={data="data", flags=f, cas=cas}, key2=...} table.
function Memcached:get(keys)
   return do_get(self, "get", keys, "^VALUE ([^ ]+) (%d+) (%d+)")
end


---Get one or more keys and unique CAS IDs for each.
-- @see get
function Memcached:gets(keys)
   return do_get(self, "gets", keys, "^VALUE ([^ ]+) (%d+) (%d+) (%d+)")
end


--==================
--= Other commands =
--==================

---Delete a key.
function Memcached:delete(key, noreply)
   key = get_key(self, key)
   local msg = fmt("delete %s%s\r\n",
                   key, noreply and " noreply" or "")
   if noreply then return self:send(msg) end
   local res, err = self:send_recv(msg)
   return res and res == "DELETED", res or false, err
end


---Flush all keys.
function Memcached:flush_all()
   return self:send_recv("flush_all\r\n")
end


local function adjust_key(self, cmd, key, val, noreply)
   key = get_key(self, key)
   assert(val, "No number")
   noreply = noreply and " noreply" or ""
   local msg = fmt("%s %s %d%s\r\n", cmd, key, val, noreply)

   if noreply ~= "" then
      return self:send(msg)
   end

   local res, err = self:send_recv(msg)
   if not res then
     return false, err
   end

  return tonumber(res)
end


---Increment key by an integer.
function Memcached:incr(key, val, noreply)
   return adjust_key(self, "incr", key, val, noreply)
end


---Decrement key by an integer.
function Memcached:decr(key, val, noreply)
   return adjust_key(self, "decr", key, val, noreply)
end


---Get a table with info about the memcached server.
function Memcached:stats(key)
   key = key or ''
   if (key ~= '') and (not STATS_KEYS[key]) then
      return error(fmt("Unknown stats key '%s'", key))
   end

   local line, err = self:send_recv("stats " ..key .. "\r\n")
   local s = {}
   while line ~= "END" do
      if not line then return false, err end
      if line == 'ERROR' then return false, "ERROR" end
      local k,v = line:match("STAT ([^ ]+) (.*)")
      if k ~= "version" then v = tonumber(v) end
      s[k] = v
      line, err = self:receive()
   end
   return s
end


---Get server version.
function Memcached:version()
   return self:send_recv("version\r\n")
end


---Close the connection to the server.
function Memcached:quit()
   return self:send_recv("quit\r\n")
end

---Non-blocking Lua client for memcached.
local _M = {}

if _G._VERSION == "Lua 5.1" then
   memcached = _M
end

---Connect to a memcached server, returning a Memcached handle.
-- @param host Defaults to localhost.
-- @param port Defaults to 11211.
-- @param defer_hook An optional function, called to defer, enabling
-- non-blocking operation.
function _M.connect(host, port, defer_hook)
   host, port = host or "localhost", port or 11211

   local m = setmetatable({
      _host=host, _port=port,
      _defer = defer_hook
   }, Memcached_mt)

   m:connect()
   return m
end

return _M
