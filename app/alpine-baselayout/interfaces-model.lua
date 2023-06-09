-- acf model for /etc/network/interfaces
-- Copyright(c) 2007 N. Angelacos - Licensed under terms of GPL2
local mymodule = {}

modelfunctions = require("modelfunctions")
fs = require("acf.fs")
format = require("acf.format")

local servicename = "networking"
local interfacesfile = "/etc/network/interfaces"

local array

-- iface is a local table with cfes for the various parts of interface definitions
-- Depending on the address family and corresponding method, different options are valid
local iface = require("alpine-baselayout/interfaces-definitions")

local followlink = function(path)
	local where = path
	while fs.is_link(where) do
		local link = posix.readlink(where)
		if link and not string.find(link, "^/") then
			link = posix.dirname(where).."/"..link
		end
		where = link
	end
	return where
end

local filename = followlink(interfacesfile)

-- Create an interface structure with all options
local get_blank_iface = function ()
	local f =  {}
	for name,table in pairs(iface.required) do
		f[name] = cfe(table)
	end

	for name,table in pairs(iface.optional) do
		f[name] = cfe(table)
	end

	return cfe({ type="group", value=f, label="Interface description" })
end

-- Get a reverse list of options valid for a given family / method
local get_options = function (family, method)
	local optional = {}
	if iface.method_options[family] and iface.method_options[family][method] then
		for i,o in ipairs(iface.method_options[family][method]) do
			optional[o] = true
		end
	end
	return optional
end

-- return the index of array entry matching "name"
local arrayindex = function (name)
	if name and #name > 0  then
		if array == nil then
			unpack_interfaces ()
		end

		for k,v in ipairs(array) do
			if name == v.value.name.value then
				return k
			end
		end
	end

	return nil
end

local appendentry  = function (self, value, prefix)
	self = self or ""
	-- if we already have some values, then append a newline
	if #self > 0  then self = self .. "\n" end
	-- strip the prefix
	local str = string.gsub(value, "^" .. ( prefix or "" ), "")
	-- and append
	return self .. str
end

local expandentry = function (self, prefix)
	if #self == 0 then
		return ""
	end
	-- force the string to end in a single linefeed
	self = string.gsub (self, "\r", "")
	self = string.gsub (self, "[\n]*$", "\n")
	local strings = {}
	for line in string.gmatch(self, "(.-)\n") do
		if #line > 0 then
			strings[#strings+1] = prefix .. line
		end
	end
	return table.concat(strings, "\n")
end

-- This function parses the interfaces file and creates array
local unpack_interfaces = function ()
	if array == nil then
		local filecontent = fs.read_file(filename) or ""
		-- make sure it has a terminating \n
		filecontent  = string.gsub (filecontent, "([^\n])$", "%1\n")

		array = {}
		local comment = ""
		local auto = {}

		for line in string.gmatch ( filecontent, "%s*([^\n]*%S)%s*\n?") do
			-- it can be #, auto, iface, or a parameter
			if string.match(line, "^#") then
				comment = appendentry(comment, line , "#%s*" )
			elseif string.match(line, "^auto") then
				local name = string.match(line, "auto%s+(%S+)")
				auto[name] = true
			elseif string.match(line, "^iface") then
				local name, family, method = string.match(line, "%S+%s+(%S+)%s+(%S+)%s+(%S+)")
				array[#array + 1] = get_blank_iface()
				local interface = array[#array].value
				interface.comment.value = comment
				comment = ""
				interface.name.value = name or ""
				interface.family.value = family or ""
				interface.method.value = method or ""
			elseif #array > 0 then
				-- it must be some kind of parameter
				local param, val =
					string.match(line, "(%S+)%s*(.*)$")
				if (param) then
					local interface = array[#array].value
					if comment ~= "" then
						interface.comment.value = appendentry(interface.comment.value, comment)
						comment = ""
					end
					if not (interface[param]) then
						interface.other.value = appendentry(interface.other.value, param.." "..val)
					else
						interface[param].value = appendentry(interface[param].value, val)
					end
				end
			end
		end
		for i,int in ipairs(array) do
			if auto[int.value.name.value] then
				int.value.auto.value = true
			end
		end
	end

	return array
end

-- This function takes array and writes the interfaces file (only writing options valid for the family/method combo)
local commit_interfaces = function()
	local str = ""
	local strings = {}
	local required = {}
	for name,value in pairs(iface.required) do
		-- Check for the ones handled by other means
		if name~="comment" and name~="name" and name~="family" and name~="method" and name~="auto" and name~="other" then
			required[name] = true
		end
	end
	for n,int in ipairs(array) do
		local me = int.value
		if me.comment.value ~= "" then
			strings[#strings+1] = expandentry(me.comment.value, "# ")
		end
		if me.auto.value then
			strings[#strings+1] = "auto " .. me.name.value
		end
		strings[#strings+1] = string.format("iface %s %s %s", me.name.value,
						me.family.value, me.method.value)
		local optional = get_options(me.family.value, me.method.value)
		for name,entry in pairs(me) do
			if (required[name] or optional[name]) and entry.value ~= "" then
				strings[#strings+1] = expandentry(entry.value, "\t"..name.." ")
			end
		end
		if me.other.value ~= "" then
			strings[#strings+1] = expandentry(me.other.value, "\t")
		end
		strings[#strings+1] = ""
	end

	local filecontent = table.concat(strings, "\n")
	fs.write_file(filename, filecontent)
end

-- Validate the interface (assuming valid family / method, will only validate the appropriate options)
local validate_interface = function (def)
	local success = true
	local optional = {}

	-- since the structure is different depending on the family and method, check them first
	success = modelfunctions.validateselect(def.value.family) and success
	success = modelfunctions.validateselect(def.value.method) and success
	if success then
		-- Validate the method (given the family)
		local method = cfe(iface.required.method)
		method.value = def.value.method.value
		method.option = {}
		if iface.family_methods[def.value.family.value] then
			method.option = iface.family_methods[def.value.family.value]
		end
		if not modelfunctions.validateselect(method) then
			def.value.method.errtxt = "Invalid method for this address family"
			success = false
		end

		-- Determine the list of valid options
		optional = get_options(def.value.family.value, def.value.method.value)
	end

	if #def.value.name.value == 0 then
		def.value.name.errtxt = "The interface must have a name"
		success = false
	elseif string.find(def.value.name.value, "%s") then
		def.value.name.errtxt = "Cannot contain spaces"
		success = false
	end

	-- More validation tests go here ---
	-- for optional fields, first check optional[name] to see if it should be validated

	if not success then
		def.errtxt = "Failed validation"
	end

	return success
end

local list_interfaces = function()
	local output = {}
	unpack_interfaces()
	for i,int in ipairs(array) do
		output[#output+1] = int.value.name.value
	end
	table.sort(output)
	return output
end

-------------------------------------------------------------------------------
-- Public Methods
-------------------------------------------------------------------------------

mymodule.get_all_interfaces = function(self, clientdata)
	unpack_interfaces()
	return cfe({ type="group", value=array, label="Interfaces" })
end

mymodule.get_iface_by_name = function(self, clientdata)
	-- if the name is blank, then return a blank iface with error
	local ret
	unpack_interfaces()
	local idx = arrayindex(clientdata.name or "")
	if not idx then
		ret = get_blank_iface()
		ret.value.name.value = name
		ret.value.name.errtxt = "Interface does not exist"
	else
		ret = array[idx]
	end
	ret.value.name.readonly = true
	return ret
end

mymodule.get_iface = function(self, clientdata)
	return get_blank_iface()
end

mymodule.create_iface = function(self, def)
	unpack_interfaces()
	local success = validate_interface( def )

	if success then
		idx = #array
		table.insert( array, idx+1, def )
		commit_interfaces()
	else
		def.errtxt = "Failed to create interface"
	end

	return def
end

mymodule.update_iface = function(self, def)
	unpack_interfaces()
	-- if the def by that name doesn't exist, fail
	local success
	local idx = arrayindex(def.value.name.value or "" )
	if not idx then
		def.value.name.errtxt = "This is an invalid interface name"
		success = false
	else
		success = validate_interface( def )
	end

	if success then
		array[idx] = def
		commit_interfaces()
	else
		def.errtxt = "Failed to update interface"
	end

	return def
end

mymodule.get_delete_iface_by_name = function(self, clientdata)
	local result = {}
	result.name = cfe({ type="select", value=clientdata.name or "", label="Interface Name", option=list_interfaces() })

	return cfe({ type="group", value=result, label="Interface Name" })
end

mymodule.delete_iface_by_name = function(self, deleterequest)
	local success = modelfunctions.validateselect(deleterequest.value.name)

	if success then
		unpack_interfaces()
		local idx = arrayindex(deleterequest.value.name.value)
		if idx then
			table.remove (array, idx )
			commit_interfaces()
			deleterequest.descr = "Interface deleted"
		else
			deleterequest.errtxt = "Interface not found"
		end
	else
		deleterequest.errtxt = "Failed to delete interface"
	end

	return deleterequest
end

mymodule.get_status = function ()
	local status = {}
	status.filename = cfe({ value=filename, label="Interfaces file" })
	status.iproute = cfe({ type="longtext", label="ip route" })
	status.ipaddr = cfe({ type="longtext", label="ip addr" })
	status.iptunnel = cfe({ type="longtext", label="ip tunnel" })

	if not fs.is_file(filename) then
		status.filename.errtxt = "File not found"
	end

	status.iproute.value, status.iproute.errtxt = modelfunctions.run_executable({"ip", "route"})
	status.ipaddr.value, status.ipaddr.errtxt = modelfunctions.run_executable({"ip", "addr"})
	status.iptunnel.value, status.iptunnel.errtxt = modelfunctions.run_executable({"ip", "tunnel"})

	return cfe({ type="group", value=status, label="Interfaces Status" })
end

mymodule.get_file = function ()
	return modelfunctions.getfiledetails(filename)
end

mymodule.write_file = function (self, newfile)
	array = nil
	return modelfunctions.setfiledetails(self, newfile, {filename})
end

mymodule.get_interfaces = function()
	local ipaddr = modelfunctions.run_executable({"ip", "addr"})
	-- now parse the result to find the interfaces
	local retval = {}
	for line in string.gmatch(ipaddr, "[^\n]*\n?") do
		if string.find(line, "^%d+:%s+") then
			local interface=string.match(line, "^%d+:%s+([^:@]+)")
			retval[#retval+1] = interface
		end
	end
	return cfe({ type="list", value=retval, label="IP Interfaces" })
end

mymodule.get_addresses = function()
	local ipaddr = modelfunctions.run_executable({"ip", "addr"})
	-- now parse the result to find the interfaces and IP addresses
	local retval = {}
	local interface
	for line in string.gmatch(ipaddr, "[^\n]*\n?") do
		if string.find(line, "^%d+:%s+") then
			interface=string.match(line, "^%d+:%s+([^:@]+)")
		elseif string.find(line, "^%s*inet%s") then
			table.insert(retval, {interface=interface, ipaddr=string.match(line, "^%s*inet%s+([%d%.]+)")})
		end
	end
	return cfe({ type="structure", value=retval, label="Interface IP Addresses" })
end

mymodule.get_ifup_by_name = function(self, clientdata)
	local result = {}
	result.name = cfe({ type="select", value=clientdata.name or "", label="Interface Name", option=list_interfaces() })

	return cfe({ type="group", value=result, label="Interface Name" })
end

mymodule.ifup_by_name = function (self, ifuprequest)
	local success = modelfunctions.validateselect(ifuprequest.value.name)
	if success then
		name = ifuprequest.value.name.value or ""
		ifuprequest.descr, ifuprequest.errtxt = modelfunctions.run_executable({"ifup", name}, true)

		if not ifuprequest.errtxt and ifuprequest.descr == "" then
			ifuprequest.descr = "Interface up"
		end
	else
		ifuprequest.errtxt = "Failed ifup"
	end

	return ifuprequest
end

mymodule.get_ifdown_by_name = function(self, clientdata)
	local result = {}
	result.name = cfe({ type="select", value=clientdata.name or "", label="Interface Name", option=list_interfaces() })

	return cfe({ type="group", value=result, label="Interface Name" })
end

mymodule.ifdown_by_name = function (self, ifdownrequest)
	local success = modelfunctions.validateselect(ifdownrequest.value.name)
	if success then
		name = ifdownrequest.value.name.value or ""
		ifdownrequest.descr, ifdownrequest.errtxt = modelfunctions.run_executable({"ifdown", name}, true)

		if not ifdownrequest.errtxt and ifdownrequest.descr == "" then
			ifdownrequest.descr = "Interface down"
		end
	else
		ifdownrequest.errtxt = "Failed ifup"
	end

	return ifdownrequest
end

mymodule.get_restartnetworking = function(self, clientdata)
	local actions = {}
	actions[1] = "restart"
	local service = cfe({ type="hidden", value=servicename, label="Service Name" })
	local startstop = cfe({ type="group", label="Restart Networking", value={servicename=service}, option=actions, descr="!! WARNING !! Restarting networking may cause the TRIИITY web interface to stop functioning. Try refreshing this page after restarting. If that fails, you may have to use terminal access to recover." })

	return startstop
end

mymodule.restartnetworking = function(self, startstop)
	return modelfunctions.startstop_service(startstop, "restart")
end

return mymodule
