module("luci.passwall2.util_xray", package.seeall)
local api = require "luci.passwall2.api"
local uci = api.uci
local sys = api.sys
local jsonc = api.jsonc
local appname = api.appname
local fs = api.fs

local new_port

local function get_new_port()
    if new_port then
        new_port = tonumber(sys.exec(string.format("echo -n $(/usr/share/%s/app.sh get_new_port %s tcp)", appname, new_port + 1)))
    else
        new_port = tonumber(sys.exec(string.format("echo -n $(/usr/share/%s/app.sh get_new_port auto tcp)", appname)))
    end
    return new_port
end

local function get_domain_excluded()
    local path = string.format("/usr/share/%s/domains_excluded", appname)
    local content = fs.readfile(path)
    if not content then return nil end
    local hosts = {}
    string.gsub(content, '[^' .. "\n" .. ']+', function(w)
        local s = w:gsub("^%s*(.-)%s*$", "%1") -- Trim
        if s == "" then return end
        if s:find("#") and s:find("#") == 1 then return end
        if not s:find("#") or s:find("#") ~= 1 then table.insert(hosts, s) end
    end)
    if #hosts == 0 then hosts = nil end
    return hosts
end

function gen_outbound(flag, node, tag, proxy_table)
    local result = nil
    if node and node ~= "nil" then
        local node_id = node[".name"]
        if tag == nil then
            tag = node_id
        end

        local proxy = 0
        local proxy_tag = "nil"
        local dialerProxy = nil
        if proxy_table ~= nil and type(proxy_table) == "table" then
            proxy = proxy_table.proxy or 0
            proxy_tag = proxy_table.tag or "nil"
            dialerProxy = proxy_table.dialerProxy
        end

        if node.type == "V2ray" or node.type == "Xray" then
            if node.type == "Xray" and node.tlsflow == "xtls-rprx-vision" then
            else
                proxy = 0
                if proxy_tag ~= "nil" then
                    if dialerProxy and dialerProxy == "1" then
                        node.streamSettings = {
                            sockopt = {
                                dialerProxy = proxy_tag
                            }
                        }
                    else
                        node.proxySettings = {
                            tag = proxy_tag,
                            transportLayer = true
                        }
                    end
                end
            end
        end

        if node.type ~= "V2ray" and node.type ~= "Xray" then
            local relay_port = node.port
            new_port = get_new_port()
            local config_file = string.format("%s_%s_%s.json", flag, tag, new_port)
            if tag and node_id and tag ~= node_id then
                config_file = string.format("%s_%s_%s_%s.json", flag, tag, node_id, new_port)
            end
            sys.call(string.format('/usr/share/%s/app.sh run_socks "%s"> /dev/null',
                appname,
                string.format("flag=%s node=%s bind=%s socks_port=%s config_file=%s relay_port=%s",
                    new_port, --flag
                    node_id, --node
                    "127.0.0.1", --bind
                    new_port, --socks port
                    config_file, --config file
                    (proxy == 1 and relay_port) and tostring(relay_port) or "" --relay port
                    )
                )
            )
            node = {}
            node.protocol = "socks"
            node.transport = "tcp"
            node.address = "127.0.0.1"
            node.port = new_port
            node.stream_security = "none"
        end
        
        if node.type == "V2ray" or node.type == "Xray" then
            if node.tls and node.tls == "1" then
                node.stream_security = "tls"
                if node.type == "Xray" and node.reality and node.reality == "1" then
                    node.stream_security = "reality"
                end
            end
        end

		if node.protocol == "wireguard" and node.wireguard_reserved then
			local bytes = {}
			node.wireguard_reserved:gsub("[^,]+", function(b)
				bytes[#bytes+1] = tonumber(b)
			end)
			node.wireguard_reserved = #bytes > 0 and bytes or nil
		end

        result = {
            _flag_tag = node_id,
            _flag_proxy = proxy,
            _flag_proxy_tag = proxy_tag,
            tag = tag,
            proxySettings = node.proxySettings or nil,
            protocol = node.protocol,
            mux = {
                enabled = (node.mux == "1") and true or false,
                concurrency = (node.mux_concurrency) and tonumber(node.mux_concurrency) or 8
            } or nil,
            -- 底层传输配置
            streamSettings = (node.streamSettings or node.protocol == "vmess" or node.protocol == "vless" or node.protocol == "socks" or node.protocol == "shadowsocks" or node.protocol == "trojan") and {
                sockopt = {
                    mark = 255,
                    dialerProxy = (node.streamSettings and dialerProxy and dialerProxy == "1") and node.streamSettings.sockopt.dialerProxy or nil
                },
                network = node.transport,
                security = node.stream_security,
                tlsSettings = (node.stream_security == "tls") and {
                    serverName = node.tls_serverName,
                    allowInsecure = (node.tls_allowInsecure == "1") and true or false,
                    fingerprint = (node.type == "Xray" and node.fingerprint and node.fingerprint ~= "") and node.fingerprint or nil
                } or nil,
                realitySettings = (node.stream_security == "reality") and {
                    serverName = node.tls_serverName,
                    publicKey = node.reality_publicKey,
                    shortId = node.reality_shortId or "",
                    spiderX = node.reality_spiderX or "/",
                    fingerprint = (node.type == "Xray" and node.fingerprint and node.fingerprint ~= "") and node.fingerprint or "chrome"
                } or nil,
                tcpSettings = (node.transport == "tcp" and node.protocol ~= "socks") and {
                    header = {
                        type = node.tcp_guise or "none",
                        request = (node.tcp_guise == "http") and {
                            path = node.tcp_guise_http_path or {"/"},
                            headers = {
                                Host = node.tcp_guise_http_host or {}
                            }
                        } or nil
                    }
                } or nil,
                kcpSettings = (node.transport == "mkcp") and {
                    mtu = tonumber(node.mkcp_mtu),
                    tti = tonumber(node.mkcp_tti),
                    uplinkCapacity = tonumber(node.mkcp_uplinkCapacity),
                    downlinkCapacity = tonumber(node.mkcp_downlinkCapacity),
                    congestion = (node.mkcp_congestion == "1") and true or false,
                    readBufferSize = tonumber(node.mkcp_readBufferSize),
                    writeBufferSize = tonumber(node.mkcp_writeBufferSize),
                    seed = (node.mkcp_seed and node.mkcp_seed ~= "") and node.mkcp_seed or nil,
                    header = {type = node.mkcp_guise}
                } or nil,
                wsSettings = (node.transport == "ws") and {
                    path = node.ws_path or "/",
                    headers = (node.ws_host ~= nil) and
                        {Host = node.ws_host} or nil,
                    maxEarlyData = tonumber(node.ws_maxEarlyData) or nil,
                    earlyDataHeaderName = (node.ws_earlyDataHeaderName) and node.ws_earlyDataHeaderName or nil
                } or nil,
                httpSettings = (node.transport == "h2") and {
                    path = node.h2_path or "/",
                    host = node.h2_host,
                    read_idle_timeout = tonumber(node.h2_read_idle_timeout) or nil,
                    health_check_timeout = tonumber(node.h2_health_check_timeout) or nil
                } or nil,
                dsSettings = (node.transport == "ds") and
                    {path = node.ds_path} or nil,
                quicSettings = (node.transport == "quic") and {
                    security = node.quic_security,
                    key = node.quic_key,
                    header = {type = node.quic_guise}
                } or nil,
                grpcSettings = (node.transport == "grpc") and {
                    serviceName = node.grpc_serviceName,
                    multiMode = (node.grpc_mode == "multi") and true or nil,
                    idle_timeout = tonumber(node.grpc_idle_timeout) or nil,
                    health_check_timeout = tonumber(node.grpc_health_check_timeout) or nil,
                    permit_without_stream = (node.grpc_permit_without_stream == "1") and true or nil,
                    initial_windows_size = tonumber(node.grpc_initial_windows_size) or nil
                } or nil
            } or nil,
            settings = {
                vnext = (node.protocol == "vmess" or node.protocol == "vless") and {
                    {
                        address = node.address,
                        port = tonumber(node.port),
                        users = {
                            {
                                id = node.uuid,
                                level = 0,
                                security = (node.protocol == "vmess") and node.security or nil,
                                encryption = node.encryption or "none",
                                flow = (node.protocol == "vless" and node.tls == '1' and node.tlsflow) and node.tlsflow or nil
                            }
                        }
                    }
                } or nil,
                servers = (node.protocol == "socks" or node.protocol == "http" or node.protocol == "shadowsocks" or node.protocol == "trojan") and {
                    {
                        address = node.address,
                        port = tonumber(node.port),
                        method = node.method or nil,
                        ivCheck = (node.protocol == "shadowsocks") and node.iv_check == "1" or nil,
                        uot = (node.protocol == "shadowsocks") and node.uot == "1" or nil,
                        password = node.password or "",
                        users = (node.username and node.password) and {
                            {
                                user = node.username,
                                pass = node.password
                            }
                        } or nil
                    }
                } or nil,
                address = (node.protocol == "wireguard" and node.wireguard_local_address) and node.wireguard_local_address or nil,
                secretKey = (node.protocol == "wireguard") and node.wireguard_secret_key or nil,
                peers = (node.protocol == "wireguard") and {
                    {
                        publicKey = node.wireguard_public_key,
                        endpoint = node.address .. ":" .. node.port,
                        preSharedKey = node.wireguard_preSharedKey,
                        keepAlive = node.wireguard_keepAlive and tonumber(node.wireguard_keepAlive) or nil
                    }
                } or nil,
                mtu = (node.protocol == "wireguard" and node.wireguard_mtu) and tonumber(node.wireguard_mtu) or nil,
                reserved = (node.protocol == "wireguard" and node.wireguard_reserved) and node.wireguard_reserved or nil
            }
        }
        local alpn = {}
        if node.alpn and node.alpn ~= "default" then
            string.gsub(node.alpn, '[^' .. "," .. ']+', function(w)
                table.insert(alpn, w)
            end)
        end
        if alpn and #alpn > 0 then
            if result.streamSettings.tlsSettings then
                result.streamSettings.tlsSettings.alpn = alpn
            end
        end
    end
    return result
end

function gen_config_server(node)
    local settings = nil
    local routing = nil
    local outbounds = {
        {protocol = "freedom", tag = "direct"}, {protocol = "blackhole", tag = "blocked"}
    }

    if node.protocol == "vmess" or node.protocol == "vless" then
        if node.uuid then
            local clients = {}
            for i = 1, #node.uuid do
                clients[i] = {
                    id = node.uuid[i],
                    flow = ("vless" == node.protocol and "1" == node.tls and node.tlsflow) and node.tlsflow or nil
                }
            end
            settings = {
                clients = clients,
                decryption = node.decryption or "none"
            }
        end
    elseif node.protocol == "socks" then
        settings = {
            udp = ("1" == node.udp_forward) and true or false,
            auth = ("1" == node.auth) and "password" or "noauth",
            accounts = ("1" == node.auth) and {
                {
                    user = node.username,
                    pass = node.password
                }
            } or nil
        }
    elseif node.protocol == "http" then
        settings = {
            allowTransparent = false,
            accounts = ("1" == node.auth) and {
                {
                    user = node.username,
                    pass = node.password
                }
            } or nil
        }
        node.transport = "tcp"
        node.tcp_guise = "none"
    elseif node.protocol == "shadowsocks" then
        settings = {
            method = node.method,
            password = node.password,
            ivCheck = ("1" == node.iv_check) and true or false,
            network = node.ss_network or "TCP,UDP"
        }
    elseif node.protocol == "trojan" then
        if node.uuid then
            local clients = {}
            for i = 1, #node.uuid do
                clients[i] = {
                    password = node.uuid[i]
                }
            end
            settings = {
                clients = clients
            }
        end
    elseif node.protocol == "mtproto" then
        settings = {
            users = {
                {
                    secret = (node.password == nil) and "" or node.password
                }
            }
        }
    elseif node.protocol == "dokodemo-door" then
        settings = {
            network = node.d_protocol,
            address = node.d_address,
            port = tonumber(node.d_port)
        }
    end

    if node.fallback and node.fallback == "1" then
        local fallbacks = {}
        for i = 1, #node.fallback_list do
            local fallbackStr = node.fallback_list[i]
            if fallbackStr then
                local tmp = {}
                string.gsub(fallbackStr, '[^' .. "," .. ']+', function(w)
                    table.insert(tmp, w)
                end)
                local dest = tmp[1] or ""
                local path = tmp[2]
                if dest:find("%.") then
                else
                    dest = tonumber(dest)
                end
                fallbacks[i] = {
                    path = path,
                    dest = dest,
                    xver = 1
                }
            end
        end
        settings.fallbacks = fallbacks
    end

    routing = {
        domainStrategy = "IPOnDemand",
        rules = {
            {
                type = "field",
                ip = {"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"},
                outboundTag = (node.accept_lan == nil or node.accept_lan == "0") and "blocked" or "direct"
            }
        }
    }

    if node.outbound_node and node.outbound_node ~= "nil" then
        local outbound = nil
        if node.outbound_node == "_iface" and node.outbound_node_iface then
            outbound = {
                protocol = "freedom",
                tag = "outbound",
                streamSettings = {
                    sockopt = {
                        interface = node.outbound_node_iface
                    }
                }
            }
        else
            local outbound_node_t = uci:get_all("passwall2", node.outbound_node)
            if node.outbound_node == "_socks" or node.outbound_node == "_http" then
                outbound_node_t = {
                    type = node.type,
                    protocol = node.outbound_node:gsub("_", ""),
                    transport = "tcp",
                    address = node.outbound_node_address,
                    port = node.outbound_node_port,
                    username = (node.outbound_node_username and node.outbound_node_username ~= "") and node.outbound_node_username or nil,
                    password = (node.outbound_node_password and node.outbound_node_password ~= "") and node.outbound_node_password or nil,
                }
            end
            outbound = require("luci.passwall2.util_xray").gen_outbound(nil, outbound_node_t, "outbound")
        end
        if outbound then
            table.insert(outbounds, 1, outbound)
        end
    end

    local config = {
        log = {
            loglevel = ("1" == node.log) and node.loglevel or "none"
        },
        -- 传入连接
        inbounds = {
            {
                listen = (node.bind_local == "1") and "127.0.0.1" or nil,
                port = tonumber(node.port),
                protocol = node.protocol,
                settings = settings,
                streamSettings = {
                    network = node.transport,
                    security = "none",
                    tlsSettings = ("1" == node.tls) and {
                        disableSystemRoot = false,
                        certificates = {
                            {
                                certificateFile = node.tls_certificateFile,
                                keyFile = node.tls_keyFile
                            }
                        }
                    } or nil,
                    tcpSettings = (node.transport == "tcp") and {
                        acceptProxyProtocol = (node.acceptProxyProtocol and node.acceptProxyProtocol == "1") and true or false,
                        header = {
                            type = node.tcp_guise,
                            request = (node.tcp_guise == "http") and {
                                path = node.tcp_guise_http_path or {"/"},
                                headers = {
                                    Host = node.tcp_guise_http_host or {}
                                }
                            } or nil
                        }
                    } or nil,
                    kcpSettings = (node.transport == "mkcp") and {
                        mtu = tonumber(node.mkcp_mtu),
                        tti = tonumber(node.mkcp_tti),
                        uplinkCapacity = tonumber(node.mkcp_uplinkCapacity),
                        downlinkCapacity = tonumber(node.mkcp_downlinkCapacity),
                        congestion = (node.mkcp_congestion == "1") and true or false,
                        readBufferSize = tonumber(node.mkcp_readBufferSize),
                        writeBufferSize = tonumber(node.mkcp_writeBufferSize),
                        seed = (node.mkcp_seed and node.mkcp_seed ~= "") and node.mkcp_seed or nil,
                        header = {type = node.mkcp_guise}
                    } or nil,
                    wsSettings = (node.transport == "ws") and {
                        acceptProxyProtocol = (node.acceptProxyProtocol and node.acceptProxyProtocol == "1") and true or false,
                        headers = (node.ws_host) and {Host = node.ws_host} or nil,
                        path = node.ws_path
                    } or nil,
                    httpSettings = (node.transport == "h2") and {
                        path = node.h2_path, host = node.h2_host
                    } or nil,
                    dsSettings = (node.transport == "ds") and {
                        path = node.ds_path
                    } or nil,
                    quicSettings = (node.transport == "quic") and {
                        security = node.quic_security,
                        key = node.quic_key,
                        header = {type = node.quic_guise}
                    } or nil,
                    grpcSettings = (node.transport == "grpc") and {
                        serviceName = node.grpc_serviceName
                    } or nil
                }
            }
        },
        -- 传出连接
        outbounds = outbounds,
        routing = routing
    }

    local alpn = {}
    if node.alpn then
        string.gsub(node.alpn, '[^' .. "," .. ']+', function(w)
            table.insert(alpn, w)
        end)
    end
    if alpn and #alpn > 0 then
        if config.inbounds[1].streamSettings.tlsSettings then
            config.inbounds[1].streamSettings.tlsSettings.alpn = alpn
        end
    end

    if "1" == node.tls then
        config.inbounds[1].streamSettings.security = "tls"
    end

    return config
end

function gen_config(var)
    local flag = var["-flag"]
    local loglevel = var["-loglevel"] or "warning"
    local node_id = var["-node"]
    local tcp_proxy_way = var["-tcp_proxy_way"]
    local redir_port = var["-redir_port"]
    local sniffing = var["-sniffing"]
    local route_only = var["-route_only"]
    local buffer_size = var["-buffer_size"]
    local local_socks_address = var["-local_socks_address"] or "0.0.0.0"
    local local_socks_port = var["-local_socks_port"]
    local local_socks_username = var["-local_socks_username"]
    local local_socks_password = var["-local_socks_password"]
    local local_http_address = var["-local_http_address"] or "0.0.0.0"
    local local_http_port = var["-local_http_port"]
    local local_http_username = var["-local_http_username"]
    local local_http_password = var["-local_http_password"]
    local dns_listen_port = var["-dns_listen_port"]
    local dns_query_strategy = var["-dns_query_strategy"]
    local direct_dns_port = var["-direct_dns_port"]
    local direct_dns_udp_server = var["-direct_dns_udp_server"]
    local remote_dns_port = var["-remote_dns_port"]
    local remote_dns_udp_server = var["-remote_dns_udp_server"]
    local remote_dns_fake = var["-remote_dns_fake"]
    local dns_cache = var["-dns_cache"]

    local dns_direct_domains = {}
    local dns_direct_expectIPs = {}
    local dns_remote_domains = {}
    local dns_remote_expectIPs = {}
    local dns = nil
    local fakedns = nil
    local inbounds = {}
    local outbounds = {}
    local routing = nil
    local observatory = nil

    if local_socks_port then
        local inbound = {
            listen = local_socks_address,
            port = tonumber(local_socks_port),
            protocol = "socks",
            settings = {auth = "noauth", udp = true},
            sniffing = {enabled = true, destOverride = {"http", "tls"}}
        }
        if local_socks_username and local_socks_password and local_socks_username ~= "" and local_socks_password ~= "" then
            inbound.settings.auth = "password"
            inbound.settings.accounts = {
                {
                    user = local_socks_username,
                    pass = local_socks_password
                }
            }
        end
        table.insert(inbounds, inbound)
    end

    if local_http_port then
        local inbound = {
            listen = local_http_address,
            port = tonumber(local_http_port),
            protocol = "http",
            settings = {allowTransparent = false}
        }
        if local_http_username and local_http_password and local_http_username ~= "" and local_http_password ~= "" then
            inbound.settings.accounts = {
                {
                    user = local_http_username,
                    pass = local_http_password
                }
            }
        end
        table.insert(inbounds, inbound)
    end

    if redir_port then
        local inbound = {
            port = tonumber(redir_port),
            protocol = "dokodemo-door",
            settings = {network = "tcp,udp", followRedirect = true},
            streamSettings = {sockopt = {tproxy = "tproxy"}},
            sniffing = {enabled = sniffing and true or false, destOverride = {"http", "tls", (remote_dns_fake) and "fakedns"}, metadataOnly = false, routeOnly = route_only and true or nil, domainsExcluded = (sniffing and not route_only) and get_domain_excluded() or nil}
        }
        local tcp_inbound = api.clone(inbound)
        tcp_inbound.tag = "tcp_redir"
        tcp_inbound.settings.network = "tcp"
        tcp_inbound.streamSettings.sockopt.tproxy = tcp_proxy_way
        table.insert(inbounds, tcp_inbound)

        local udp_inbound = api.clone(inbound)
        udp_inbound.tag = "udp_redir"
        udp_inbound.settings.network = "udp"
        table.insert(inbounds, udp_inbound)
    end

    local nodes = {}
    if node_id then
        local node = uci:get_all(appname, node_id)
        if node then
            nodes[node_id] = node
        end
    end

    for k, v in pairs(nodes) do
        local node = v
        if node.protocol == "_shunt" then
            local rules = {}

            local default_node_id = node.default_node or "_direct"
            local default_outboundTag
            if default_node_id == "_direct" then
                default_outboundTag = "direct"
            elseif default_node_id == "_blackhole" then
                default_outboundTag = "blackhole"
            else
                local default_node = uci:get_all(appname, default_node_id)
                local main_node_id = node.main_node or "nil"
                local proxy = 0
                local proxy_tag
                if main_node_id ~= "nil" then
                    local main_node = uci:get_all(appname, main_node_id)
                    if main_node and api.is_normal_node(main_node) and main_node_id ~= default_node_id then
                        local main_node_outbound = gen_outbound(flag, main_node, "main")
                        if main_node_outbound then
                            table.insert(outbounds, main_node_outbound)
                            proxy = 1
                            proxy_tag = "main"
                            local pre_proxy = nil
                            if default_node.type ~= "V2ray" and default_node.type ~= "Xray" then
                                pre_proxy = true
                            end
                            if default_node.type == "Xray" and default_node.tlsflow == "xtls-rprx-vision" then
                                pre_proxy = true
                            end
                            if pre_proxy then
                                proxy_tag = nil
                                new_port = get_new_port()
                                table.insert(inbounds, {
                                    tag = "proxy_default",
                                    listen = "127.0.0.1",
                                    port = new_port,
                                    protocol = "dokodemo-door",
                                    settings = {network = "tcp,udp", address = default_node.address, port = tonumber(default_node.port)}
                                })
                                if default_node.tls_serverName == nil then
                                    default_node.tls_serverName = default_node.address
                                end
                                default_node.address = "127.0.0.1"
                                default_node.port = new_port
                                table.insert(rules, 1, {
                                    type = "field",
                                    inboundTag = {"proxy_default"},
                                    outboundTag = "main"
                                })
                            end
                        end
                    end
                end
                if default_node and api.is_normal_node(default_node) then
                    local default_outbound = gen_outbound(flag, default_node, "default", { proxy = proxy, tag = proxy_tag, dialerProxy = node.dialerProxy })
                    if default_outbound then
                        table.insert(outbounds, default_outbound)
                        default_outboundTag = "default"
                    end
                end
            end

            uci:foreach(appname, "shunt_rules", function(e)
                local name = e[".name"]
                if name and e.remarks then
                    local _node_id = node[name] or "nil"
                    local proxy_tag = node[name .. "_proxy_tag"] or "nil"
                    local outboundTag
                    if _node_id == "_direct" then
                        outboundTag = "direct"
                    elseif _node_id == "_blackhole" then
                        outboundTag = "blackhole"
                    elseif _node_id == "_default" then
                        outboundTag = "default"
                    else
                        if _node_id ~= "nil" then
                            local _node = uci:get_all(appname, _node_id)
                            if _node and api.is_normal_node(_node) then
                                local new_outbound
                                for index, value in ipairs(outbounds) do
                                    if value["_flag_tag"] == _node_id and value["_flag_proxy_tag"] == proxy_tag then
                                        new_outbound = api.clone(value)
                                        break
                                    end
                                end
                                if new_outbound then
                                    new_outbound["tag"] = name
                                    table.insert(outbounds, new_outbound)
                                    outboundTag = name
                                else
                                    local pre_proxy = nil
                                    if _node.type ~= "V2ray" and _node.type ~= "Xray" then
                                        pre_proxy = true
                                    end
                                    if _node.type == "Xray" and _node.tlsflow == "xtls-rprx-vision" then
                                        pre_proxy = true
                                    end
                                    if pre_proxy then
                                        if proxy_tag ~= "nil" then
                                            new_port = get_new_port()
                                            table.insert(inbounds, {
                                                tag = "proxy_" .. name,
                                                listen = "127.0.0.1",
                                                port = new_port,
                                                protocol = "dokodemo-door",
                                                settings = {network = "tcp,udp", address = _node.address, port = tonumber(_node.port)}
                                            })
                                            if _node.tls_serverName == nil then
                                                _node.tls_serverName = _node.address
                                            end
                                            _node.address = "127.0.0.1"
                                            _node.port = new_port
                                            table.insert(rules, 1, {
                                                type = "field",
                                                inboundTag = {"proxy_" .. name},
                                                outboundTag = proxy_tag
                                            })
                                        end
                                    end
                                    local _outbound = gen_outbound(flag, _node, name, { proxy = (proxy_tag ~= "nil") and 1 or 0, tag = (proxy_tag ~= "nil") and proxy_tag or nil, dialerProxy = node.dialerProxy })
                                    if _outbound then
                                        table.insert(outbounds, _outbound)
                                        outboundTag = name
                                    end
                                end
                            end
                        end
                    end
                    if outboundTag then
                        if outboundTag == "default" then 
                            outboundTag = default_outboundTag
                        end
                        local protocols = nil
                        if e["protocol"] and e["protocol"] ~= "" then
                            protocols = {}
                            string.gsub(e["protocol"], '[^' .. " " .. ']+', function(w)
                                table.insert(protocols, w)
                            end)
                        end
                        local domains = nil
                        if e.domain_list then
                            domains = {}
                            string.gsub(e.domain_list, '[^' .. "\r\n" .. ']+', function(w)
                                table.insert(domains, w)
                                if outboundTag == "direct" then
                                    table.insert(dns_direct_domains, w)
                                else
                                    if outboundTag ~= "nil" then
                                        table.insert(dns_remote_domains, w)
                                    end
                                end
                            end)
                        end
                        local ip = nil
                        if e.ip_list then
                            ip = {}
                            string.gsub(e.ip_list, '[^' .. "\r\n" .. ']+', function(w)
                                table.insert(ip, w)
                                if outboundTag == "direct" then
                                    table.insert(dns_direct_expectIPs, w)
                                else
                                    if outboundTag ~= "nil" then
                                        table.insert(dns_remote_expectIPs, w)
                                    end
                                end
                            end)
                        end
                        local source = nil
                        if e.source then
                            source = {}
                            string.gsub(e.source, '[^' .. " " .. ']+', function(w)
                                table.insert(source, w)
                            end)
                        end
                        local rule = {
                            _flag = e.remarks,
                            type = "field",
                            outboundTag = outboundTag,
                            network = e["network"] or "tcp,udp",
                            source = source,
                            sourcePort = e["sourcePort"] ~= "" and e["sourcePort"] or nil,
                            port = e["port"] ~= "" and e["port"] or nil,
                            protocol = protocols
                        }
                        if domains then
                            local _rule = api.clone(rule)
                            _rule["_flag"] = _rule["_flag"] .. "_domains"
                            _rule.domains = domains
                            table.insert(rules, _rule)
                        end
                        if ip then
                            local _rule = api.clone(rule)
                            _rule["_flag"] = _rule["_flag"] .. "_ip"
                            _rule.ip = ip
                            table.insert(rules, _rule)
                        end
                        if not domains and not ip then
                            table.insert(rules, rule)
                        end
                    end
                end
            end)

            if default_outboundTag then 
                table.insert(rules, {
                    _flag = "defalut",
                    type = "field",
                    outboundTag = default_outboundTag,
                    network = "tcp,udp"
                })
            end

            routing = {
                domainStrategy = node.domainStrategy or "AsIs",
                domainMatcher = node.domainMatcher or "hybrid",
                rules = rules
            }
        elseif node.protocol == "_balancing" then
            if node.balancing_node then
                local nodes = node.balancing_node
                local length = #nodes
                for i = 1, length do
                    local node = uci:get_all(appname, nodes[i])
                    local outbound = gen_outbound(flag, node)
                    if outbound then table.insert(outbounds, outbound) end
                end
				if node.balancingStrategy == "leastPing" then
					observatory = {
						subjectSelector = nodes,
						probeInterval = node.probeInterval or "1m"
					}
				end
                routing = {
                    balancers = {{
						tag = "balancer",
						selector = nodes,
						strategy = {type = node.balancingStrategy or "random"}
					}},
                    rules = {
                        {type = "field", network = "tcp,udp", balancerTag = "balancer"}
                    }
                }
            end
        else
            local outbound = nil
            if node.protocol == "_iface" then
                if node.iface then
                    outbound = {
                        protocol = "freedom",
                        tag = "outbound",
                        streamSettings = {
                            sockopt = {
                                interface = node.iface
                            }
                        }
                    }
                end
            else
                outbound = gen_outbound(flag, node)
            end
            if outbound then table.insert(outbounds, outbound) end
            routing = {
                domainStrategy = "AsIs",
                domainMatcher = "hybrid",
                rules = {}
            }
            table.insert(routing.rules, {
                _flag = "defalut",
                type = "field",
                outboundTag = node_id,
                network = "tcp,udp"
            })
        end

    end
    
    if remote_dns_udp_server or remote_dns_fake then
        local rules = {}
        local _remote_dns_proto
    
        if not routing then
            routing = {
                domainStrategy = "IPOnDemand",
                rules = {}
            }
        end
    
        dns = {
            tag = "dns-in1",
            hosts = {},
            disableCache = (dns_cache and dns_cache == "0") and true or false,
            disableFallback = true,
            disableFallbackIfMatch = true,
            servers = {},
            queryStrategy = (dns_query_strategy and dns_query_strategy ~= "") and dns_query_strategy or "UseIP"
        }
    
        local dns_host = ""
        if flag == "global" then
            dns_host = uci:get(appname, "@global[0]", "dns_hosts") or ""
        else
            flag = flag:gsub("acl_", "")
            local dns_hosts_mode = uci:get(appname, flag, "dns_hosts_mode") or "default"
            if dns_hosts_mode == "default" then
                dns_host = uci:get(appname, "@global[0]", "dns_hosts") or ""
            elseif dns_hosts_mode == "disable" then
                dns_host = ""
            elseif dns_hosts_mode == "custom" then
                dns_host = uci:get(appname, flag, "dns_hosts") or ""
            end
        end
        if #dns_host > 0 then
            string.gsub(dns_host, '[^' .. "\r\n" .. ']+', function(w)
                local host = sys.exec(string.format("echo -n $(echo %s | awk -F ' ' '{print $1}')", w))
                local key = sys.exec(string.format("echo -n $(echo %s | awk -F ' ' '{print $2}')", w))
                if host ~= "" and key ~= "" then
                    dns.hosts[host] = key
                end
            end)
        end
    
        if true then
            local _remote_dns = {
                _flag = "remote",
                domains = #dns_remote_domains > 0 and dns_remote_domains or nil
                --expectIPs = #dns_remote_expectIPs > 0 and dns_remote_expectIPs or nil
            }
    
            if remote_dns_udp_server then
                _remote_dns.address = remote_dns_udp_server
                _remote_dns.port = tonumber(remote_dns_port) or 53
                _remote_dns_proto = "udp"
    
                table.insert(routing.rules, 1, {
                    type = "field",
                    ip = {
                        remote_dns_udp_server
                    },
                    port = tonumber(remote_dns_port) or 53,
                    network = "udp",
                    outboundTag = "direct"
                })
            end
    
            if remote_dns_fake then
                fakedns = {}
                fakedns[#fakedns + 1] = {
                    ipPool = "198.18.0.0/16",
                    poolSize = 65535
                }
                if dns_query_strategy == "UseIP" then
                    fakedns[#fakedns + 1] = {
                        ipPool = "fc00::/18",
                        poolSize = 65535
                    }
                end
                _remote_dns.address = "fakedns"
            end
    
            table.insert(dns.servers, _remote_dns)
        end
    
        if true then
            local nodes_domain_text = sys.exec('uci show passwall2 | grep ".address=" | cut -d "\'" -f 2 | grep "[a-zA-Z]$" | sort -u')
            string.gsub(nodes_domain_text, '[^' .. "\r\n" .. ']+', function(w)
                table.insert(dns_direct_domains, "full:" .. w)
            end)
    
            local _direct_dns = {
                _flag = "direct",
                domains = #dns_direct_domains > 0 and dns_direct_domains or nil
                --expectIPs = #dns_direct_expectIPs > 0 and dns_direct_expectIPs or nil
            }
    
            if direct_dns_udp_server then
                _direct_dns.address = direct_dns_udp_server
                _direct_dns.port = tonumber(direct_dns_port) or 53
                table.insert(routing.rules, 1, {
                    type = "field",
                    ip = {
                        direct_dns_udp_server
                    },
                    port = tonumber(direct_dns_port) or 53,
                    network = "udp",
                    outboundTag = "direct"
                })
            end
    
            table.insert(dns.servers, _direct_dns)
        end
    
        if dns_listen_port then
            table.insert(inbounds, {
                listen = "127.0.0.1",
                port = tonumber(dns_listen_port),
                protocol = "dokodemo-door",
                tag = "dns-in",
                settings = {
                    address = "1.1.1.1",
                    port = 53,
                    network = "tcp,udp"
                }
            })
            local direct_type_dns = {
                settings = {
                    address = direct_dns_udp_server,
                    port = tonumber(direct_dns_port) or 53,
                    network = "udp"
                },
                proxySettings = {
                    tag = "direct"
                }
            }
            local remote_type_dns = {
                settings = {
                    address = remote_dns_udp_server,
                    port = tonumber(remote_dns_port) or 53,
                    network = _remote_dns_proto or "tcp"
                },
                proxySettings = {
                    tag = "direct"
                }
            }
            local custom_type_dns = {
                settings = {
                    address = "1.1.1.1",
                    port = 53,
                    network = "tcp",
                }
            }
            local type_dns = remote_type_dns
            table.insert(outbounds, {
                tag = "dns-out",
                protocol = "dns",
                proxySettings = type_dns.proxySettings,
                settings = type_dns.settings
            })
            table.insert(routing.rules, 1, {
                type = "field",
                inboundTag = {
                    "dns-in"
                },
                outboundTag = "dns-out"
            })
        end
    
        local default_dns_flag = "remote"
        if node_id and redir_port then
            local node = uci:get_all(appname, node_id)
            if node.protocol == "_shunt" then
                if node.default_node == "_direct" then
                    default_dns_flag = "direct"
                end
            end
        end
    
        if dns.servers and #dns.servers > 0 then
            local dns_servers = nil
            for index, value in ipairs(dns.servers) do
                if not dns_servers and value["_flag"] == default_dns_flag then
                    dns_servers = {
                        _flag = "default",
                        address = value.address,
                        port = value.port
                    }
                    break
                end
            end
            if dns_servers then
                table.insert(dns.servers, 1, dns_servers)
            end
        end
    
        local default_rule_index = #routing.rules > 0 and #routing.rules or 1
        for index, value in ipairs(routing.rules) do
            if value["_flag"] == "default" then
                default_rule_index = index
                break
            end
        end
        for index, value in ipairs(rules) do
            local t = rules[#rules + 1 - index]
            table.insert(routing.rules, default_rule_index, t)
        end
    
        local dns_hosts_len = 0
        for key, value in pairs(dns.hosts) do
            dns_hosts_len = dns_hosts_len + 1
        end
    
        if dns_hosts_len == 0 then
            dns.hosts = nil
        end
    end
    
    if inbounds or outbounds then
        local config = {
            log = {
                --access = string.format("/tmp/etc/%s/%s_access.log", appname, "global"),
                --error = string.format("/tmp/etc/%s/%s_error.log", appname, "global"),
                --dnsLog = true,
                loglevel = loglevel
            },
            -- DNS
            dns = dns,
            fakedns = fakedns,
            -- 传入连接
            inbounds = inbounds,
            -- 传出连接
            outbounds = outbounds,
            -- 连接观测
			observatory = observatory,
            -- 路由
            routing = routing,
            -- 本地策略
            policy = {
                levels = {
                    [0] = {
                        -- handshake = 4,
                        -- connIdle = 300,
                        -- uplinkOnly = 2,
                        -- downlinkOnly = 5,
                        bufferSize = buffer_size and tonumber(buffer_size) or nil,
                        statsUserUplink = false,
                        statsUserDownlink = false
                    }
                },
                -- system = {
                --     statsInboundUplink = false,
                --     statsInboundDownlink = false
                -- }
            }
        }
        table.insert(outbounds, {
            protocol = "freedom",
            tag = "direct",
            settings = {
                domainStrategy = (dns_query_strategy and dns_query_strategy ~= "") and dns_query_strategy or "UseIPv4"
            },
            streamSettings = {
                sockopt = {
                    mark = 255
                }
            }
        })
        table.insert(outbounds, {
            protocol = "blackhole",
            tag = "blackhole"
        })
        return jsonc.stringify(config, 1)
    end
end

function gen_proto_config(var)
    local local_socks_address = var["-local_socks_address"] or "0.0.0.0"
    local local_socks_port = var["-local_socks_port"]
    local local_socks_username = var["-local_socks_username"]
    local local_socks_password = var["-local_socks_password"]
    local local_http_address = var["-local_http_address"] or "0.0.0.0"
    local local_http_port = var["-local_http_port"]
    local local_http_username = var["-local_http_username"]
    local local_http_password = var["-local_http_password"]
    local server_proto = var["-server_proto"]
    local server_address = var["-server_address"]
    local server_port = var["-server_port"]
    local server_username = var["-server_username"]
    local server_password = var["-server_password"]
    
    local inbounds = {}
    local outbounds = {}
    local routing = nil

    if local_socks_address and local_socks_port then
        local inbound = {
            listen = local_socks_address,
            port = tonumber(local_socks_port),
            protocol = "socks",
            settings = {
                udp = true,
                auth = "noauth"
            }
        }
        if local_socks_username and local_socks_password and local_socks_username ~= "" and local_socks_password ~= "" then
            inbound.settings.auth = "password"
            inbound.settings.accounts = {
                {
                    user = local_socks_username,
                    pass = local_socks_password
                }
            }
        end
        table.insert(inbounds, inbound)
    end
    
    if local_http_address and local_http_port then
        local inbound = {
            listen = local_http_address,
            port = tonumber(local_http_port),
            protocol = "http",
            settings = {
                allowTransparent = false
            }
        }
        if local_http_username and local_http_password and local_http_username ~= "" and local_http_password ~= "" then
            inbound.settings.accounts = {
                {
                    user = local_http_username,
                    pass = local_http_password
                }
            }
        end
        table.insert(inbounds, inbound)
    end
    
    if server_proto ~= "nil" and server_address ~= "nil" and server_port ~= "nil" then
        local outbound = {
            protocol = server_proto,
            streamSettings = {
                network = "tcp",
                security = "none"
            },
            settings = {
                servers = {
                    {
                        address = server_address,
                        port = tonumber(server_port),
                        users = (server_username and server_password) and {
                            {
                                user = server_username,
                                pass = server_password
                            }
                        } or nil
                    }
                }
            }
        }
        if outbound then table.insert(outbounds, outbound) end
    end
    
    -- 额外传出连接
    table.insert(outbounds, {
        protocol = "freedom", tag = "direct", settings = {keep = ""}
    })
    
    local config = {
        log = {
            loglevel = "warning"
        },
        -- 传入连接
        inbounds = inbounds,
        -- 传出连接
        outbounds = outbounds,
        -- 路由
        routing = routing
    }
    return jsonc.stringify(config, 1)
end

function gen_dns_config(var)
    local dns_listen_port = var["-dns_listen_port"]
    local dns_query_strategy = var["-dns_query_strategy"]
    local dns_out_tag = var["-dns_out_tag"]
    local dns_client_ip = var["-dns_client_ip"]
    local direct_dns_server = var["-direct_dns_server"]
    local direct_dns_port = var["-direct_dns_port"]
    local direct_dns_udp_server = var["-direct_dns_udp_server"]
    local direct_dns_tcp_server = var["-direct_dns_tcp_server"]
    local direct_dns_doh_url = var["-direct_dns_doh_url"]
    local direct_dns_doh_host = var["-direct_dns_doh_host"]
    local remote_dns_server = var["-remote_dns_server"]
    local remote_dns_port = var["-remote_dns_port"]
    local remote_dns_udp_server = var["-remote_dns_udp_server"]
    local remote_dns_tcp_server = var["-remote_dns_tcp_server"]
    local remote_dns_doh_url = var["-remote_dns_doh_url"]
    local remote_dns_doh_host = var["-remote_dns_doh_host"]
    local remote_dns_outbound_socks_address = var["-remote_dns_outbound_socks_address"]
    local remote_dns_outbound_socks_port = var["-remote_dns_outbound_socks_port"]
    local remote_dns_fake = var["-remote_dns_fake"]
    local dns_cache = var["-dns_cache"]
    local loglevel = var["-loglevel"] or "warning"
    
    local inbounds = {}
    local outbounds = {}
    local dns = nil
    local fakedns = nil
    local routing = nil

    if dns_listen_port then
        routing = {
            domainStrategy = "IPOnDemand",
            rules = {}
        }
    
        dns = {
            tag = "dns-in1",
            hosts = {},
            disableCache = (dns_cache == "1") and false or true,
            disableFallback = true,
            disableFallbackIfMatch = true,
            servers = {},
            clientIp = (dns_client_ip and dns_client_ip ~= "") and dns_client_ip or nil,
            queryStrategy = (dns_query_strategy and dns_query_strategy ~= "") and dns_query_strategy or "UseIPv4"
        }
    
        local other_type_dns_proto, other_type_dns_server, other_type_dns_port
    
        if dns_out_tag == "remote" then
            local _remote_dns = {
                _flag = "remote"
            }

            if remote_dns_fake then
                remote_dns_server = "1.1.1.1"
                fakedns = {}
                fakedns[#fakedns + 1] = {
                    ipPool = "198.18.0.0/16",
                    poolSize = 65535
                }
                if dns_query_strategy == "UseIP" then
                    fakedns[#fakedns + 1] = {
                        ipPool = "fc00::/18",
                        poolSize = 65535
                    }
                end
                _remote_dns.address = "fakedns"
            end

            other_type_dns_port = tonumber(remote_dns_port) or 53
            other_type_dns_server = remote_dns_server
    
            if remote_dns_udp_server then
                _remote_dns.address = remote_dns_udp_server
                _remote_dns.port = tonumber(remote_dns_port) or 53
                other_type_dns_proto = "udp"
            end
    
            if remote_dns_tcp_server then
                _remote_dns.address = remote_dns_tcp_server
                _remote_dns.port = tonumber(remote_dns_port) or 53
                other_type_dns_proto = "tcp"
            end
    
            if remote_dns_doh_url and remote_dns_doh_host then
                if remote_dns_server and remote_dns_doh_host ~= remote_dns_server and not api.is_ip(remote_dns_doh_host) then
                    dns.hosts[remote_dns_doh_host] = remote_dns_server
                end
                _remote_dns.address = remote_dns_doh_url
                _remote_dns.port = tonumber(remote_dns_port) or 443
                other_type_dns_proto = "tcp"
                other_type_dns_port = 53
            end
    
            table.insert(dns.servers, _remote_dns)
            table.insert(outbounds, 1, {
                tag = "remote",
                protocol = "socks",
                streamSettings = {
                    network = "tcp",
                    security = "none"
                },
                settings = {
                    servers = {
                        {
                            address = remote_dns_outbound_socks_address,
                            port = tonumber(remote_dns_outbound_socks_port)
                        }
                    }
                }
            })
        elseif dns_out_tag == "direct" then
            local _direct_dns = {
                _flag = "direct"
            }

            other_type_dns_proto = tonumber(direct_dns_port) or 53
            other_type_dns_server = direct_dns_server
    
            if direct_dns_udp_server then
                _direct_dns.address = direct_dns_udp_server
                _direct_dns.port = tonumber(direct_dns_port) or 53
                table.insert(routing.rules, 1, {
                    type = "field",
                    ip = {
                        direct_dns_udp_server
                    },
                    port = tonumber(direct_dns_port) or 53,
                    network = "udp",
                    outboundTag = "direct"
                })
            end

            if direct_dns_udp_server then
                _direct_dns.address = direct_dns_udp_server
                _direct_dns.port = tonumber(direct_dns_port) or 53
                other_type_dns_proto = "udp"
            end
    
            if direct_dns_tcp_server then
                _direct_dns.address = direct_dns_tcp_server:gsub("tcp://", "tcp+local://")
                _direct_dns.port = tonumber(direct_dns_port) or 53
                other_type_dns_proto = "tcp"
            end
    
            if direct_dns_doh_url and direct_dns_doh_host then
                if direct_dns_server and direct_dns_doh_host ~= direct_dns_server and not api.is_ip(direct_dns_doh_host) then
                    dns.hosts[direct_dns_doh_host] = direct_dns_server
                end
                _direct_dns.address = direct_dns_doh_url:gsub("https://", "https+local://")
                _direct_dns.port = tonumber(direct_dns_port) or 443
                other_type_dns_proto = "tcp"
                other_type_dns_port = 53
            end
    
            table.insert(dns.servers, _direct_dns)
    
            table.insert(outbounds, 1, {
                protocol = "freedom",
                tag = "direct",
                settings = {
                    domainStrategy = (dns_query_strategy and dns_query_strategy ~= "") and dns_query_strategy or "UseIPv4"
                },
                streamSettings = {
                    sockopt = {
                        mark = 255
                    }
                }
            })
        end
    
        local dns_hosts_len = 0
        for key, value in pairs(dns.hosts) do
            dns_hosts_len = dns_hosts_len + 1
        end
    
        if dns_hosts_len == 0 then
            dns.hosts = nil
        end
    
        table.insert(inbounds, {
            listen = "127.0.0.1",
            port = tonumber(dns_listen_port),
            protocol = "dokodemo-door",
            tag = "dns-in",
            settings = {
                address = other_type_dns_server or "1.1.1.1",
                port = 53,
                network = "tcp,udp"
            }
        })
    
        table.insert(outbounds, {
            tag = "dns-out",
            protocol = "dns",
            proxySettings = {
                tag = dns_out_tag
            },
            settings = {
                address = other_type_dns_server or "1.1.1.1",
                port = other_type_dns_port or 53,
                network = other_type_dns_proto or "tcp",
            }
        })
    
        table.insert(routing.rules, 1, {
            type = "field",
            inboundTag = {
                "dns-in"
            },
            outboundTag = "dns-out"
        })
    
        table.insert(routing.rules, {
            type = "field",
            inboundTag = {
                "dns-in1"
            },
            outboundTag = dns_out_tag
        })
    end
    
    if inbounds or outbounds then
        local config = {
            log = {
                --dnsLog = true,
                loglevel = loglevel
            },
            -- DNS
            dns = dns,
            fakedns = fakedns,
            -- 传入连接
            inbounds = inbounds,
            -- 传出连接
            outbounds = outbounds,
            -- 路由
            routing = routing
        }
        return jsonc.stringify(config, 1)
    end
    
end

_G.gen_config = gen_config
_G.gen_proto_config = gen_proto_config
_G.gen_dns_config = gen_dns_config

if arg[1] then
    local func =_G[arg[1]]
    if func then
        print(func(api.get_function_args(arg)))
    end
end
