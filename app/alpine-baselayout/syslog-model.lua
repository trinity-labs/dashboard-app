local mymodule = {}

modelfunctions = require("modelfunctions")
fs = require("acf.fs")
format = require("acf.format")
validator = require("acf.validator")

local configfile = "/etc/conf.d/syslog"
local packagename = "busybox"
local processname = "syslog"

local function getloglevels()
	local loglevels = {}
	for i=1,8 do
		table.insert(loglevels,tostring(i))
	end
	return loglevels
end

local writeconfig = function (config)
	-- Set variables
	local variable = "SYSLOGD_OPTS"
	local variabletranslator = {
		logfile = "-O",
		loglevel = "-l",
		smallerlogs = "-S",
		maxsize = "-s",
		numrotate = "-b",
		localandnetworklog = "-L",
		remotelogging = "-R",
		}

	local configdata = {}

	for name, entry in pairs(variabletranslator) do
		if config.value[name] and config.value[name].type == "boolean" then
			if config.value[name].value then configdata[entry] = "" end
		elseif config.value[name] and config.value[name].value and #config.value[name].value > 0 then
			configdata[entry] = config.value[name].value
		else
			configdata[entry] = nil
		end
	end

	fs.write_file(configfile, format.update_ini_file(fs.read_file(configfile) or "", "", variable, '"'..format.table_to_opts(configdata) .. '"'))
end

local makeconfig = function(configcontent)
	local config = {}
	configcontent = configcontent or {}
	-- Next section selects which configurations we should show to the user
	config["logfile"] = cfe({
		label = "Log to given file",
		descr = "File must be in /var/log directory",
		value = configcontent["-O"] or "/var/log/messages",
		})
	config["loglevel"] = cfe({
		label = "Set local log level",
		value = configcontent["-l"] or "8",
		type = "select",
		option = getloglevels(),
		descr = "1=Quiet, ... , " .. #getloglevels() .. "=Debug", -- Make Lua >=5.3 compat 20230406 - TRIИITY
		})
	config["smallerlogs"] = cfe({
		label = "Smaller logging output",
		value = (configcontent["-S"] == ""),
		type = "boolean",
		})
	config["maxsize"] = cfe ({
		label = "Max size (KB) before rotate",
		descr = "Default=200KB, 0=off",
		value = configcontent["-s"] or "",
		})
	config["numrotate"] = cfe ({
		label = "Number of rotated logs to keep",
		descr = "Default=1, max=99, 0=purge",
		value = configcontent["-b"] or "",
		})
	config["localandnetworklog"] = cfe ({
		label = "Log locally and via network",
		value = (configcontent["-L"] == ""),
		type = "boolean",
		descr = "Default is network only if host[:PORT] is defined",
		})
	config["remotelogging"] = cfe ({
		label = "Log to IP or hostname on PORT",
		descr = "host[:PORT] - Default PORT=514/UDP",
		value = configcontent["-R"] or "",
		})

	return cfe({ type="group", value=config, label="Configuration" })
end

local validateconfig = function(config)
	local success = true
	-- Validate entries and create error strings
	if not validator.is_valid_filename(config.value.logfile.value, "/var/log") then
		config.value.logfile.errtxt = "Not a valid file name in /var/log"
		success = false
	end
	if not validator.is_integer_in_range(config.value.loglevel.value, 1, 8) then
		config.value.loglevel.errtxt = "Out of range!"
		success = false
	end
	if config.value.maxsize.value ~= "" and not validator.is_integer(config.value.maxsize.value) then
		config.value.maxsize.errtxt = "Must be an integer"
		success = false
	end
	if config.value.numrotate.value ~= "" and not validator.is_integer_in_range(config.value.numrotate.value, 0, 99) then
		config.value.numrotate.errtxt = "Out of range!"
		success = false
	end
	if config.value.localandnetworklog.value == true and config.value.remotelogging.value == "" then
		config.value.localandnetworklog.errtxt = "Logging to local and network is not possible unless you define a host for remote logging"
		success = false
	end
	local hostport = format.string_to_table(config.value.remotelogging.value, ":")
	if hostport[2] and not (validator.is_port(hostport[2])) then
		config.value.remotelogging.errtxt = "Not a valid port"
		success = false
	end

	return success, config
end

local validate_configfile = function(filedetails)
	local success = true

	local configcontent = format.opts_to_table(string.sub((format.parse_ini_file(filedetails.value.filecontent.value, "", "SYSLOGD_OPTS") or ""),2,-2))
	local config = makeconfig(configcontent)
	success, config = validateconfig(config)
	if not success then
		local errormessages = {}
		for x,y in pairs(config.value) do
			if y.errtxt then
				errormessages[#errormessages + 1] = y.label .. " - " .. y.errtxt
			end
		end
		filedetails.value.filecontent.errtxt = table.concat(errormessages, "\n")
	end

	return success, filedetails
end

-- ################################################################################
-- PUBLIC FUNCTIONS

function mymodule.get_startstop(self, clientdata)
	return modelfunctions.get_startstop(processname)
end

function mymodule.startstop_service(self, startstop, action)
	return modelfunctions.startstop_service(startstop, action)
end

function mymodule.getstatus()
	return modelfunctions.getstatus(processname, packagename, "Syslog Status")
end

function mymodule.getlogging()
	local status = {}
	local opts = mymodule.getconfig()
	if (opts.value.remotelogging.value == "") or (opts.value.localandnetworklog.value) then
		status.logfile = cfe({
			label="Locally logging to",
			value=opts.value.logfile.value,
			})
	end
	if (opts.value.remotelogging.value ~= "") then
		status.remote = cfe({
			label="Remote logging to",
			value=opts.value.remotelogging.value,
			})
	end

	return cfe({ type="group", value=status, label="Logging Details" })
end

function mymodule.get_filedetails()
	return modelfunctions.getfiledetails(configfile)
end

function mymodule.getconfig()
	local config = {}
	if (fs.is_file(configfile)) then
		local configcontent = format.opts_to_table(string.sub((format.parse_ini_file(fs.read_file(configfile) or "", "", "SYSLOGD_OPTS") or ""),2,-2))
		config = makeconfig(configcontent)
	else
		config = makeconfig()
		config["errtxt"] = "Config file '".. configfile .. "' is missing!"
	end

	return config
end

function mymodule.updateconfig (self, config)
	local success = true
	success, config = validateconfig(config)

	if success == true then
		writeconfig(config)
	else
		config.errtxt = "Failed to save config!"
	end

	return config
end

function mymodule.update_filedetails (self, filedetails)
	return modelfunctions.setfiledetails(self, filedetails, {configfile}, validate_configfile)
end

return mymodule
