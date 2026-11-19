-- 首页手动只读补全：只取最近三本，每本最多六份墨桥载荷和一份 Moon+ 当前位置。
-- 不打开阅读器，不调用跳转、上传、清理或 Cloud:sync；关闭页面后也不强制重开。
local Sync = {}

function Sync.refresh(plugin, books, callback)
    local UI = require("ui/uimanager")
    if Sync.running then callback(false, "正在读取同步历史，请稍候。") return end
    if not plugin.server or plugin.server.type ~= "webdav" then
        callback(false, "尚未配置墨桥 WebDAV 目录，请先进入设置。") return
    end
    local Network = require("ui/network/manager")
    if not Network:isConnected() then
        callback(false, "当前离线，未读取云端；已有缓存仍保留。") return
    end
    local History = require("inkbridge_home_history")
    local State = require("inkbridge_state")
    local WebDAV = require("inkbridge_webdav")
    local Moon = require("inkbridge_moon")
    local Moonsync = require("inkbridge_moonsync")
    local active, count, issues = true, 0, {}
    Sync.running = true
    local watchdog
    local function finish(ok, message)
        if not active then return end
        active = false
        Sync.running = nil
        UI:unschedule(watchdog)
        callback(ok, message or (string.format("已读取 %d 条真实同步正文。", count)
            .. (#issues > 0 and ("\n部分来源未取到：" .. table.concat(issues, "；")) or "")))
    end
    watchdog = function() finish(false, "读取超时，已完成的记录保留；请检查网络后重试。") end
    UI:scheduleIn(60, watchdog)
    local function defer(fn)
        UI:nextTick(function()
            if not active then return end
            if not Network:isConnected() then finish(false, "网络已断开，已读取的记录保留。") return end
            local ok = pcall(fn)
            if not ok then finish(false, "读取失败，已有记录保留；请检查同步配置后重试。") end
        end)
    end
    local function save(book, id, entry, source, note)
        if not active then return end
        local ok, added = pcall(History.add, book.file, entry, source, os.time(), id, note)
        if ok and added then count = count + 1
        elseif not ok then issues[#issues + 1] = book.title .. "（本地缓存保存失败）" end
    end
    local index = 0
    local next_book
    next_book = function()
        index = index + 1
        if index > math.min(#books, 3) then finish(true) return end
        local book = books[index]
        local id = State.book_id(book.file) -- 校验完整身份，不只凭文件名或短哈希入库。
        if not id then
            issues[#issues + 1] = book.title .. "（原书身份无法核对）"
            defer(next_book) return
        end
        local function read_moon()
            -- 独立只读上下文；不能给真实 FileManager 临时塞 document。
            local proxy = { server = plugin.server, ui = { document = { file = book.file } } }
            local body = Moonsync.fetch_po(proxy)
            local po = body and Moon.parse(body)
            local location, err
            if po then location, err = Moonsync.position_from_po(book.file, po) end
            if location and location.snippet then
                save(book, id, { text_anchor = location.snippet,
                    character_percent = location.character_percent }, "静读天下", location.anchor_note)
            else
                issues[#issues + 1] = book.title .. "（静读天下：" .. tostring(err or "无可还原位置") .. "）"
            end
            defer(next_book)
        end
        WebDAV.list_history(plugin, id:sub(1, 8), function(ok, entries)
            if not active then return end
            if not ok or type(entries) ~= "table" then
                issues[#issues + 1] = book.title .. "（墨桥历史未取到）"
                defer(read_moon) return
            end
            local item_index = 0
            local seen = {}
            local function read_entry()
                item_index = item_index + 1
                local item = entries[item_index]
                if item_index > 6 or not item then defer(read_moon) return end
                WebDAV.download(plugin, item.url, function(download_ok, remote)
                    if not active then return end
                    if download_ok and type(remote) == "table" and remote.book_id == id then
                        local source = "墨桥 · " .. tostring(remote.device_label or "远端")
                        local key = source .. "\n" .. tostring(remote.text_anchor or "")
                        if not seen[key] then
                            seen[key] = true
                            save(book, id, remote, source)
                        end
                    elseif download_ok and type(remote) == "table" and remote.book_id ~= id then
                        issues[#issues + 1] = book.title .. "（异书历史已拒绝）"
                    elseif not download_ok then
                        issues[#issues + 1] = book.title .. "（一份墨桥历史读取失败）"
                    end
                    defer(read_entry)
                end)
            end
            defer(read_entry)
        end)
    end
    defer(next_book)
end

return Sync
