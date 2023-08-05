local RemoteNeovimConfig = require("remote-nvim")
local SSHExecutor = require("remote-nvim.providers.ssh.ssh_executor")
local SSHUtils = require("remote-nvim.providers.ssh.ssh_utils")
local utils = require("remote-nvim.utils")
local logger = utils.logger

---@alias os_type "macOS"|"Windows"|"Linux"

---@class NeovimSSHProvider
---@field remote_host string Remote host to connect to
---@field connection_options string Connection options needed to connect to remote host
---@field ssh_executor SSHRemoteExecutor Executor over which jobs will be executed
---@field remote_neovim_home string Remote path on which remote neovim will install things
---@field unique_host_identifier string Unique identifier for the host
---@field workspace_config WorkspaceConfig Workspace config for remote host
---@field local_nvim_install_script_path string Local path where Neovim installation script is stored
---@field local_nvim_user_config_path string Local path where Neovim configuration files are stored
---@field local_nvim_scripts_path string Local path where Remote Neovim scripts are stored
---@field local_free_port string Free port available on the local
---@field remote_os os_type Remote host's OS
---@field remote_neovim_version string Neovim version on the remote host
---@field remote_is_windows boolean Flag indicating whether the remote system is windows
---@field remote_workspace_id string Workspace ID associated with remote neovim
---@field remote_workspaces_path  string Path to remote workspaces on remote host
---@field remote_scripts_path  string Path to scripts path on the remote host
---@field remote_workspace_id_path  string Path to the workspace associated with the remote host
---@field remote_xdg_config_path  string Get workspace specific XDG config path
---@field remote_neovim_config_path  string Get neovim configuration path on the remote host
---@field remote_neovim_install_script_path  string Get Neovim installation script path on the remote host
---@field remote_free_port string Free port available on the remote
---@field remote_port_forwarding_job_id number Job ID for the port forwarding job
local NeovimSSHProvider = {}
NeovimSSHProvider.__index = NeovimSSHProvider

---Generate a new instance of NeovimSSHProvider
---@param host string Remote host name
---@param connection_options? string|table Connection options to connect with the host
function NeovimSSHProvider:new(host, connection_options)
  ---@type NeovimSSHProvider
  local instance = setmetatable({}, NeovimSSHProvider)

  assert(host ~= nil, "Host cannot be nil")
  instance.remote_host = host

  if connection_options ~= nil then
    if type(connection_options) == "table" then
      instance.connection_options = table.concat(connection_options, " ")
    else
      instance.connection_options = connection_options
    end
  else
    instance.connection_options = ""
  end
  instance.connection_options = SSHUtils.clean_up_conn_opts(instance.remote_host, instance.connection_options)
  instance.ssh_executor = SSHExecutor:new(instance.remote_host, instance.connection_options)

  -- Neovim configuration variables
  instance.remote_neovim_home = RemoteNeovimConfig.config.remote_neovim_install_home
  instance.unique_host_identifier = SSHUtils.get_host_identifier(instance.remote_host, instance.connection_options)

  -- Local machine-related configuration variables
  instance.local_nvim_install_script_path = RemoteNeovimConfig.config.neovim_install_script_path
  instance.local_nvim_user_config_path = RemoteNeovimConfig.config.neovim_user_config_path
  instance.local_nvim_scripts_path = utils.path_join(utils.is_windows, utils.get_package_root(), "scripts")
  instance.local_free_port = nil

  -- Remote machine-related configuration variables
  instance.remote_os = nil
  instance.remote_neovim_version = nil
  instance.remote_is_windows = nil
  instance.workspace_config = nil
  instance.remote_workspace_id = nil
  instance.remote_workspaces_path = nil
  instance.remote_scripts_path = nil
  instance.remote_workspace_id_path = nil
  instance.remote_xdg_config_path = nil
  instance.remote_neovim_config_path = nil
  instance.remote_neovim_install_script_path = nil
  instance.remote_free_port = nil
  instance.remote_port_forwarding_job_id = nil

  return instance
end

---@private
---@async
---Detect and register the OS of the remote SSH host
---@return os_type os_name Name of the OS running on remote host
function NeovimSSHProvider:detect_remote_os()
  self:run_command("Checking OS type", "uname")
  local stdout_lines = self.ssh_executor:get_stdout()
  local remote_os = stdout_lines[#stdout_lines]

  -- If we know the OS, we set it
  if remote_os == "Linux" then
    self.remote_os = "Linux"
  elseif remote_os == "Darwin" then
    self.remote_os = "macOS"
  end

  -- Time to ask this question to the user
  if self.remote_os == nil then
    local os_options = {
      "Linux",
      "macOS",
      "Windows",
    }
    utils.get_user_selection(os_options, {
      prompt = "Select your remote host's OS: ",
      format_item = function(item)
        return "Remote host is running " .. item
      end,
    }, function(choice)
      self.remote_os = choice
    end)
  end

  return self.remote_os
end

---@private
---@async
---Determine the neovim version to be deployed on the remote system
---@return string neovim_version Remote Neovim version
function NeovimSSHProvider:determine_remote_neovim_version()
  -- Time to ask user which Neovim version they want to deploy
  if self.remote_neovim_version == nil then
    -- Get all versions that are greater than minimum neovim version requirements
    local valid_neovim_versions = utils.get_neovim_versions()

    -- Get client version
    local api_info = vim.version()
    local client_version = "v" .. table.concat({ api_info.major, api_info.minor, api_info.patch }, ".")

    utils.get_user_selection(valid_neovim_versions, {
      prompt = "What Neovim version should be installed on remote host?",
      format_item = function(ver)
        if ver == client_version then
          return "Install Neovim " .. ver .. " (Your client version)"
        end
        return "Install Neovim " .. ver
      end,
    }, function(choice)
      self.remote_neovim_version = choice
    end)
  end
  return self.remote_neovim_version
end

---@private
---@async
---Setup workspace configuration variables
function NeovimSSHProvider:setup_workspace_config_vars()
  if not RemoteNeovimConfig.host_workspace_config:host_record_exists(self.unique_host_identifier) then
    local remote_os = self:detect_remote_os()
    local neovim_version = self:determine_remote_neovim_version()

    -- Save host configuration to config file
    RemoteNeovimConfig.host_workspace_config:add_host_config(self.unique_host_identifier, {
      provider = "ssh",
      host = self.remote_host,
      connection_options = self.connection_options,
      remote_neovim_home = self.remote_neovim_home,
      os = remote_os,
      neovim_version = neovim_version,
      workspace_id = utils.generate_random_string(10),
    })
  end
  self.workspace_config = RemoteNeovimConfig.host_workspace_config:get_workspace_config(self.unique_host_identifier)

  -- Set variables to their recorded values
  self.remote_os = self.workspace_config.os
  self.remote_is_windows = self.remote_os == "Windows" and true or false
  self.remote_neovim_version = self.workspace_config.neovim_version
  self.connection_options = self.connection_options or self.workspace_config.connection_options

  -- Setup remote host path variables
  self.remote_neovim_home = self.workspace_config.remote_neovim_home
  self.remote_workspaces_path = utils.path_join(self.remote_is_windows, self.remote_neovim_home, "workspaces")
  self.remote_scripts_path = utils.path_join(self.remote_is_windows, self.remote_neovim_home, "scripts")
  self.remote_neovim_install_script_path = utils.path_join(
    self.remote_is_windows,
    self.remote_scripts_path,
    (function()
      local install_script_path_components = utils.split(self.local_nvim_install_script_path, utils.is_windows)
      return install_script_path_components[#install_script_path_components]
    end)()
  )

  -- Setup workspace path variables
  self.remote_workspace_id = self.workspace_config.workspace_id
  self.remote_workspace_id_path =
    utils.path_join(self.remote_is_windows, self.remote_workspaces_path, self.remote_workspace_id)
  self.remote_xdg_config_path = utils.path_join(self.remote_is_windows, self.remote_workspace_id_path, ".config")
  self.remote_neovim_config_path = utils.path_join(self.remote_is_windows, self.remote_xdg_config_path, "nvim")
end

---Verify if we can connect to the remote host
---@async
function NeovimSSHProvider:verify_connection()
  self:run_command("Checking if remote host is reachable", 'echo "OK"')
  if self.ssh_executor.exit_code ~= 0 then
    error("Could not connect to the remote host: " .. self.unique_host_identifier)
  end
end

---@private
---@async
---Decide if we want to copy over Neovim configuration to the remote or not
function NeovimSSHProvider:handle_neovim_config_update_on_remote()
  local copy_config_choice = false

  --- Get user choice about copying the Neovim configuration over
  utils.get_user_selection({ "Yes", "No" }, {
    prompt = "Copy Neovim config at " .. self.local_nvim_user_config_path .. " ?",
  }, function(choice)
    copy_config_choice = choice == "Yes" and true or false
  end)

  if copy_config_choice then
    self:upload(
      "Copying local neovim configuration onto remote machine",
      self.local_nvim_user_config_path,
      self.remote_neovim_config_path
    )
  end
end

---@private
---Get Neovim binary path on the remote server
---@return string nvim_bin_path Path to the remote neovim binary
function NeovimSSHProvider:get_remote_neovim_binary_path()
  return utils.path_join(
    self.remote_is_windows,
    self.remote_neovim_home,
    "nvim-downloads",
    self.remote_neovim_version,
    "bin",
    "nvim"
  )
end

---@private
---Launch the remote neovim server and port forward it to a local free port
---@return NeovimSSHProvider provider The provider which is handling the executor running the command
function NeovimSSHProvider:handle_remote_server_launch()
  -- We need to launch a remote server if any of these criterias are not satisfied:
  -- 1. There is no port forwarding job running (checked by self.remote_port_forwarding_job_id)
  -- 2. The recorded port forwarding job has died, so we need to start a new instance
  if
    self.remote_port_forwarding_job_id == nil
    or not (vim.fn.jobwait({ self.remote_port_forwarding_job_id }, 0)[1] == -1)
  then
    -- Find free port on the remote server
    local free_port_cmd = self:get_remote_neovim_binary_path()
      .. " -l "
      .. utils.path_join(self.remote_is_windows, self.remote_scripts_path, "free_port_finder.lua")
    self:run_command("Finding a free port on local machine", free_port_cmd)
    local free_port_output = self.ssh_executor:get_stdout()
    self.remote_free_port = free_port_output[#free_port_output]

    -- Find free port on our local server
    self.local_free_port = utils.find_free_port()

    -- Setup SSH port forwarding connection options
    local forwarded_ports = self.local_free_port .. ":localhost:" .. self.remote_free_port
    local port_forward_ssh_opts = self.connection_options .. " -t -L " .. forwarded_ports

    -- Generate remote server launch command
    local remote_port_forwarding_cmd = ([[XDG_CONFIG_HOME=%s %s --listen 0.0.0.0:%s --headless]]):format(
      self.remote_xdg_config_path,
      self:get_remote_neovim_binary_path(),
      self.remote_free_port
    )

    -- Launch remote server and port forward to local
    local p = coroutine.create(function()
      self:run_command(
        "Launching remote neovim server with port forwarding",
        remote_port_forwarding_cmd,
        port_forward_ssh_opts
      )
    end)
    local success, err = coroutine.resume(p)
    if not success then
      print("Coroutine failed because " .. err)
    end
    self.remote_port_forwarding_job_id = self.ssh_executor.job_id
  end

  return self
end

---Launch local Neovim client and connect to the correct port
---@async
function NeovimSSHProvider:handle_local_client_launch()
  -- Launch remote server if it is not already running
  self:handle_remote_server_launch()

  local function launch_local_client(cmd)
    require("lazy.util").float_term(cmd, {
      interactive = true,
      on_exit_handler = function(_, exit_code)
        if exit_code ~= 0 then
          vim.notify("Local Neovim server " .. table.concat(cmd, " ") .. " failed")
        end
      end,
    })
  end

  utils.get_user_selection({ "Yes", "No" }, {
    prompt = "Start Neovim client here?",
  }, function(choice)
    local cmd = { "nvim", "--server", "localhost:" .. self.local_free_port, "--remote-ui" }
    if choice == "Yes" then
      launch_local_client(cmd)
    else
      vim.notify("You can connect to the remote server using " .. table.concat(cmd, " "))
    end
  end)
end

---Clean up remote host information so that we can start afresh
---@async
---@return NeovimSSHProvider provider Provider handling the clean up of the remote host
function NeovimSSHProvider:clean_up_remote_host()
  utils.run_code_in_coroutine(function()
    -- Verify that we are able to connect with the remote server
    self:verify_connection()
    self:setup_workspace_config_vars()

    -- Get user input about what should be deleted
    utils.get_user_selection({
      "Delete just my workspace (Useful if multiple people work in the same space)",
      "Delete everything remote-neovim on remote",
    }, {
      prompt = "What should be cleaned up?",
    }, function(choice)
      if choice == "Delete just my workspace (Useful if multiple people work in the same space)" then
        self:run_command("Deleting workspace on remote host", "rm -rf " .. self.remote_workspace_id_path)
      elseif choice == "Delete everything remote-neovim on remote" then
        self:run_command("Deleting remote neovim from remote host", "rm -rf " .. self.remote_neovim_home)
      end
    end)

    -- Remove record of the workspace
    RemoteNeovimConfig.host_workspace_config:delete_workspace(self.unique_host_identifier)
  end)

  return self
end

---Setup the remote host
---@async
---@return NeovimSSHProvider provider Provider handling setup of the remote host
function NeovimSSHProvider:set_up_remote()
  utils.run_code_in_coroutine(function()
    -- Verify that we are able to connect with the remote server
    self:verify_connection()
    self:setup_workspace_config_vars()

    -- Create neovim directories on the remote server
    local mkdir_cmd = ([[mkdir -p %s && mkdir -p %s && mkdir -p %s]]):format(
      self.remote_workspaces_path,
      self.remote_scripts_path,
      self.remote_xdg_config_path
    )
    self:run_command("Creating necessary directories on remote machine", mkdir_cmd)

    -- We now copy over all scripts that we have onto the remote server
    self:upload("Copying remote neovim scripts onto remote", self.local_nvim_scripts_path, self.remote_neovim_home)
    self:upload(
      "Copying custom installation script onto remote",
      self.local_nvim_install_script_path,
      self.remote_scripts_path
    )

    -- Make the installation script executable and run it to install the specified version of Neovim
    local install_neovim_cmd = ([[chmod +x %s && %s -v %s -d %s]]):format(
      self.remote_neovim_install_script_path,
      self.remote_neovim_install_script_path,
      self.remote_neovim_version,
      self.remote_neovim_home
    )
    self:run_command(("Installing Neovim %s on remote machine"):format(self.remote_neovim_version), install_neovim_cmd)

    -- Time to copy over Neovim configuration (if needed)
    self:handle_neovim_config_update_on_remote()

    -- Start remote neovim server
    self:handle_local_client_launch()
  end)

  return self
end

---Run SSH download job inside a pcall and handle any errors gracefully
---@param desc string Description of the download job being run
---@param remote_path string Remote path where it should be copied over
---@param local_path string Local path to be copied over
function NeovimSSHProvider:download(desc, remote_path, local_path, ...)
  logger.fmt_debug(
    "Running download from remote %s on %s over SSH to local %s path",
    remote_path,
    self.remote_host,
    local_path
  )
  local succ, ret = pcall(self.ssh_executor.download, self.ssh_executor, remote_path, local_path, ...)
  if not succ then
    error(([[Download from %s over SSH failed to start. Run :RemoteNvimLog for more details]]):format(self.remote_host))
  end
  self.running_job_msg = desc
  return ret
end

---Run SSH upload job inside a pcall and handle any errors gracefully
---@param desc string Description of the upload job being run
---@param local_path string Local path to be copied over
---@param remote_path string Remote path where it should be copied over
function NeovimSSHProvider:upload(desc, local_path, remote_path, ...)
  logger.fmt_debug("Running upload from local %s path over SSH to %s on %s", local_path, self.remote_host, remote_path)
  local succ, ret = pcall(self.ssh_executor.upload, self.ssh_executor, local_path, remote_path, ...)
  if not succ then
    error(([[Upload to %s over SSH failed to start. Run :RemoteNvimLog for more details]]):format(self.remote_host))
  end
  self.running_job_msg = desc
  return ret
end

---Run SSH command inside a pcall and handle any errors gracefully
---@param desc string Description of the operation being run
---@param command string Command to run over SSH
function NeovimSSHProvider:run_command(desc, command, ...)
  logger.fmt_debug("Running %s over SSH on %s", command, self.remote_host)
  local succ, ret = pcall(self.ssh_executor.run_command, self.ssh_executor, command, ...)
  if not succ then
    error(([['%s' job failed to start. Run :RemoteNvimLog for more details]]):format(desc))
  end
  self.running_job_msg = desc
  return ret
end

return NeovimSSHProvider