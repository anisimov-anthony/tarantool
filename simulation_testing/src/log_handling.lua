local fiber = require('fiber')
local fio = require('fio')
local json = require("json")
local xlog = require('xlog')


local crash_functions = require("crash_functions")
local tools = require("tools")

--local is_node_alive_by_alias = require("crash_functions").is_node_alive_by_alias


-- Function for reading the xlog
local function read_xlog(file_path)

    local file_stat = fio.stat(file_path)
    if not file_stat then
        error("File does not exist: " .. file_path)
    end
    if file_stat:is_dir() then
        error("Provided file_path is a directory, not a file: " .. file_path)
    end

    local xlog_entries = {}
    for _, entry in xlog.pairs(file_path) do
        table.insert(xlog_entries, setmetatable(entry, { __serialize = "map" }))
    end

    return xlog_entries
end

--Function of getting the latest xlog in the directory
local function get_latest_xlog(wal_dir)
    local latest_xlog = nil
    local latest_time = 0

    local xlog_files = fio.glob(wal_dir .. '/*.xlog')
    if not xlog_files or #xlog_files == 0 then
        return nil, "No .xlog files in the directory: " .. wal_dir
    end

    for _, file in ipairs(xlog_files) do
        local file_info = fio.stat(file)
        if file_info and file_info.mtime > latest_time then
            latest_time = file_info.mtime
            latest_xlog = file
        end
    end

    return latest_xlog
end

-- Function of inserting a monotonously increasing key into a space

local function periodic_insert(cg, space_name, i_0, step, interval)
    fiber.create(function(cg, space_name, i_0, step, interval)
        local key = i_0
        while true do
            local ok, err = pcall(function()
                
                local leader_node = tools.get_leader(cg.replicas)

                if leader_node == nil then
                    local leader_waiting_interval = 1
                    LogInfo("[PERIODIC INSERT] No leader found. Retrying in " .. leader_waiting_interval .. " seconds...")
                    fiber.sleep(leader_waiting_interval)
                else
                    local value = "Value for key " .. key
                    local operation_args = {key, value}

                    local insert_status, insert_result = pcall(function()
                        leader_node:exec(function(operation_args, space_name)
                            box.begin({txn_isolation = 'linearizable'})
                            box.space[space_name]:insert(operation_args)
                            box.commit()
                        end, {operation_args, space_name})
                    end)

                    if insert_status then
                        if _G.SUCCESSFUL_LOGS then
                            LogInfo("[PERIODIC INSERT] Successfully inserted key: " .. key ..
                                    ", value: " .. value ..
                                    ", into space: '" .. space_name .. "'")
                        end
                        key = key + step
                    else
                        --- Belated key case
                        local exists_status, exists_result = pcall(function()
                            return leader_node:exec(function(k, space_name)
                                return box.space[space_name]:get(k) ~= nil
                            end, {key, space_name})
                        end)

                        if exists_status and exists_result then
                            if _G.SUCCESSFUL_LOGS then
                                LogInfo("[PERIODIC INSERT] Key " .. key .. " already exists. Incrementing key and retrying...")
                            end
                            key = key + step
                        elseif not exists_status then
                            LogError("[PERIODIC INSERT] Failed to check existence of key: " .. key .. ". Error: " .. json.encode(exists_result))
                        ---
                        else
                            LogInfo("[PERIODIC INSERT] Failed to execute insert operation for key: " .. key .. 
                                    ", value: " .. value ..
                                    ", into space: '" .. space_name ..
                                    "'. Retrying in " .. interval .. " seconds..." ..
                                    " Error: " .. json.encode(insert_result))
                        end

                        fiber.sleep(interval)
                    end
                
                end
            end) 

            if not ok then
                LogError("[PERIODIC INSERT] " .. json.encode(err))
            end

            fiber.sleep(interval)
        end
    end, cg, space_name, i_0, step, interval)
end


-- Function of getting the last n entries for a space from a node
local function get_last_n_entries(node, space_name, n)
    
    local success, result = pcall(function()
        if crash_functions.is_node_alive_by_alias(node) then
            return node:exec(function(space_name, n)
                local space = box.space[space_name]
                if not space then
                    LogError(string.format("[GET LAST ENTRIES] Space '%s' does not exist.", space_name))
                    return nil;
                end

                local entries = space:select(nil, {iterator = 'REQ', limit = n})
                return entries
            end, {space_name, n})
        end
    end)

    if not success then
        return nil
    end

    if type(result) ~= "table" then
        LogError(string.format("[GET LAST ENTRIES][Node %s] Unexpected result format", node.alias))
        return nil
    end

    local count = #result
    if count ~= n then
        LogError(string.format("[GET LAST ENTRIES][Node %s] Expected %d entries, but got %d", node.alias, n, count))
        return nil
    end

    return result
end

-- Function for finding the largest total length of the intersection of the entries intervals
local function find_max_common_length(entries_by_node, step)

    local intervals = {}

    for _, entries in pairs(entries_by_node) do

        table.sort(entries, function(a, b) return a[1] < b[1] end)

        if #entries > 0 then
            -- Check that the keys go in increments
            local valid = true
            local keys_list = {}

            for i = 1, #entries do
                table.insert(keys_list, entries[i][1]) -- сохраняем весь список ключей
            end

            for i = 2, #entries do
                if entries[i][1] - entries[i-1][1] ~= step then
                    valid = false
                    break
                end
            end

            -- If the keys go monotonously in increments, keep the interval
            if valid then
                local first_key = entries[1][1]
                local last_key = entries[#entries][1]
                table.insert(intervals, {first_key, last_key})
            else
                LogError("[DIVERGENCE MONITOR] The key sequence is not monotonous! Full sequence: " .. table.concat(keys_list, ", "))
            end
        end
    end

    if #intervals == 0 then
        LogInfo("No intervals found.")
        return 0
    end

    -- todo: optimize
    local first_keys = {}
    local last_keys = {}
    for _, interval in ipairs(intervals) do
        table.insert(first_keys, interval[1])
        table.insert(last_keys, interval[2])
    end

    local max_first_key = first_keys[1]
    for _, key in ipairs(first_keys) do
        if key > max_first_key then
            max_first_key = key
        end
    end

    local min_last_key = last_keys[1]
    for _, key in ipairs(last_keys) do
        if key < min_last_key then
            min_last_key = key
        end
    end

    local common_length = min_last_key - max_first_key + 1

    return common_length
end

-- Function of monitoring the number of divergent entries in logs
local function divergence_monitor(cg, space_name, n, step, interval)
    fiber.create(function()
        local count = 0
        while true do
            local valid_nodes = {}
            -- Wrapped the entire cycle in pcall for safe execution
            local success, err = pcall(function()

                valid_nodes = crash_functions.get_non_crashed_nodes( 
                    cg.replicas,
                    crash_functions.nodes_activity_states
                )

                if #valid_nodes > 0 then

                    local entries_by_node = {}
                    local all_entries_recieved = true

                    for _, node in ipairs(valid_nodes) do
            
                        local success, result = pcall(function()
                            if crash_functions.is_node_alive_by_alias(node) then
                                if  n < count  then
                                    return get_last_n_entries(node, space_name, n)
                                end
                                return  get_last_n_entries(node, space_name, count)
                            end
                        end)

                        if success then
                            if result then
                                entries_by_node[node.alias] = result
                            else
                                LogInfo(string.format("[DIVERGENCE MONITOR] No entries found for node '%s'.", node.alias))
                                all_entries_recieved = false
                            end
                        else
                            LogInfo(string.format("[DIVERGENCE MONITOR] Error fetching entries from node '%s': %s", node.alias, result))
                            all_entries_recieved = false
                        end
                    end

                    if all_entries_recieved then
                        local common_length = find_max_common_length(entries_by_node, step)
                        local divergence
                        if n < count then
                            divergence = n - common_length
                        else
                            divergence = count - common_length
                        end

                        if _G.SUCCESSFUL_LOGS then
                            LogInfo(string.format("[DIVERGENCE MONITOR] Divergence of entries: %d", divergence))
                        else
                            if divergence ~= 0 then
                                LogInfo(string.format("[DIVERGENCE MONITOR] Divergence of entries: %d", divergence))
                            end
                        end
                    else
                        LogInfo("[DIVERGENCE MONITOR] Skipping divergence calculation as some nodes have missing entries.")
                    end
                else
                    LogInfo("[DIVERGENCE MONITOR] No valid nodes available. Retrying...")
                end
            end)

            if not success then
                LogError("[DIVERGENCE MONITOR]" .. json.encode(err))
            end
            fiber.sleep(interval)
            count = count + 1
        end
    end)
end


return {
    read_xlog = read_xlog,
    get_latest_xlog = get_latest_xlog,
    periodic_insert = periodic_insert,
    divergence_monitor = divergence_monitor,
}