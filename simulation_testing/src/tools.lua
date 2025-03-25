local function is_follower(conn)
    return conn:call('box.info').ro == true
end

-- List search function
local function contains(tbl, value)
    for _, v in ipairs(tbl) do
        if v == value then
            return true
        end
    end
    return false
end

-- For the convenience of displaying tables
local function table_to_string(tbl)
    if type(tbl) ~= "table" then
        return tostring(tbl)
    end
    local result = {}
    for _, v in ipairs(tbl) do
        table.insert(result, tostring(v))
    end
    return "{" .. table.concat(result, ", ") .. "}"
end

-- Calculating the delay
local function calculate_delay(min_delay, max_delay)

    if min_delay < 0 or max_delay < min_delay then
        error(string.format(
            "Invalid delay values: min_delay (%d) should be >= 0 and <= max_delay (%d)", 
            min_delay, max_delay
        ))
    end

    local delay = math.random(min_delay, max_delay);
    return delay
end

local function check_node(node)
    if not node then
        error("The node is not specified")
    end
end

local function get_initial_replication(nodes)
    local initial_replication = {}
    for _, node in ipairs(nodes) do
        local replication = node:exec(function()
            return box.cfg.replication
        end)
        initial_replication[node.alias] = replication
    end
    return initial_replication
end

local function get_random_node(nodes, timeout)
    if not nodes or #nodes == 0 then
        error("Node list is empty or nil")
    end

    for _, node in ipairs(nodes) do
        local ok, result = pcall(function()
            return node:eval("return true", {}, {timeout = timeout})
        end)

        if ok and result then
            return node
        end
    end

    error("No connected nodes available")
end

-- The leader's getting function, which has been modified to take into account that some nodes may be unavailable
local function get_leader(servers)
    for _, server in ipairs(servers) do
        local ok, is_ro = pcall(function()
            return server:exec(function() return box.info.ro end)
        end)

        if ok and is_ro == false then
            return server
        end
    end
    return nil 
end

-- Generates all combinations of size k from arp table elements
local function combinations(arr, k)
    local result = {}
    local n = #arr
    
    -- Auxiliary recursive function
    local function helper(start, current_comb)
        if #current_comb == k then
            table.insert(result, current_comb)
            return
        end
        
        for i = start, n do
            local new_comb = {}
            -- Copy the existing combination
            for _, v in ipairs(current_comb) do table.insert(new_comb, v) end
            -- Adding a new element
            table.insert(new_comb, arr[i])
            -- Continue recursively
            helper(i + 1, new_comb)
        end
    end
    
    helper(1, {})
    return result
end


return {
    contains = contains,
    is_follower = is_follower,
    table_to_string = table_to_string,
    calculate_delay = calculate_delay,
    check_node = check_node,
    get_initial_replication = get_initial_replication,
    get_random_node = get_random_node,
    get_leader = get_leader,
    combinations = combinations

}