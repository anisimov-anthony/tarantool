local is_node_alive_by_id = require("crash_functions").is_node_alive_by_id
local connection_exists = require("crash_functions").connection_exists

local monitor_config = {
    leader_absent_time = 10, 
    max_terms_change_by_period = 5,
    terms_change_period = 10,
    check_interval = 2,
}

local function monitor_replication(cg)
    local fiber = require('fiber')


    local state = {
        term_changes = {}, 
        last_leader_check = fiber.time(),
        last_leader_term = nil,
    }

    while true do
        local ok, err = pcall(function()

            local leaders = {}
            local problems = {}
            local now = fiber.time()

            for id, node in ipairs(cg.replicas) do
                local ok_inner, replication_info, election_info = pcall(function()
                    return node:exec(function()
                        return box.info.replication, box.info.election
                    end)
                end)
                
                if not ok_inner then
                    goto continue
                end

                if (election_info.state == 'leader') then
                    table.insert(leaders, node.id)
                end

                ----------------------------------------------------------------------------
                -- Работа с term_changes
                local current_term = election_info.term
                if current_term ~= state.last_leader_term then
                    state.last_leader_term = current_term
                    table.insert(state.term_changes, now)
                end

                for i = #state.term_changes, 1, -1 do
                    if now - state.term_changes[i] > monitor_config.terms_change_period then
                        table.remove(state.term_changes, i)
                    end
                end

                if #state.term_changes > monitor_config.max_terms_change_by_period then
                    table.insert(problems, '['..node.alias..'] Too many term changes in the last ' .. tostring(#state.term_changes) .. ' rounds')
                end

                ----------------------------------------------------------------------------
                -- Проверка задержек
                for replica_id, replica in pairs(replication_info) do
                    if connection_exists(id, replica_id) == false then
                        goto internal_continue -- skip
                    end
                    if replica.upstream then
                        local lag = replica.upstream.lag or 0
                        
                        if lag > 2 then 
                            table.insert(problems, '['..node.alias..'] High lag detected on upstream with replica_' .. replica_id)
                        end
                    end
                    if replica.downstream then
                        local lag = replica.downstream.lag or 0
                        if lag > 2 then 
                            table.insert(problems, '['..node.alias..'] High lag detected on downstream replica_' .. replica_id)
                        end
                    end
                    ::internal_continue::
                end

                ----------------------------------------------------------------------------
                -- Проверка статуса соединений
                for replica_id, replica in pairs(replication_info) do
                    if is_node_alive_by_id(replica_id) == false or connection_exists(id, replica_id) == false then
                        goto next_iteration
                    end
                    if replica.upstream and replica.upstream.status == 'disconnected' then
                        table.insert(problems, '['..node.alias..'] Upstream disconnected for node ' .. replica_id)
                    end
                    if replica.downstream and replica.downstream.status == 'disconnected' then
                        table.insert(problems, '['..node.alias..'] Downstream disconnected for node ' .. replica_id)
                    end
                    ::next_iteration::
                end

                ::continue::
            end

            ----------------------------------------------------------------------------
            for _, leader in ipairs(leaders) do
                LogInfo("[REPLICATION MONITOR][CLUSTER] Leader: "..leader)
            end

            if #leaders == 0 then
                if now - state.last_leader_check > monitor_config.leader_absent_time then
                    table.insert(problems, '[CLUSTER] No leader detected for more than ' .. monitor_config.leader_absent_time .. ' seconds')
                end
            else
                state.last_leader_check = now
            end

            if #leaders > 1 then
                table.insert(problems, '[REPLICATION MONITOR][CLUSTER] Multiple leaders detected')
            end

            LogInfo('[REPLICATION MONITOR][CLUSTER] Detected '..tostring(#problems)..' Problems:')

            if #problems > 0 then
                for _, problem in ipairs(problems) do
                    LogInfo('[REPLICATION MONITOR] '.. problem)
                end
            end
        end)

        if not ok then
            LogError('[REPLICATION MONITOR]', err)
        end

        fiber.sleep(monitor_config.check_interval)
    end
end

return {
    run_replication_monitor = monitor_replication,
    monitor_config = monitor_config,
}