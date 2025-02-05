{ config, lib, pkgs, ... }:
with lib;
with lib.my;
let
  cfg = importTOML ../../data/monitoring.toml;
  hostName = config.networking.hostName;
  getHost = (y:
    if (y == hostName)
    then "127.0.0.1"
    else
      (
        if (builtins.elem y (builtins.attrNames cfg.hostOverrides))
        then cfg.hostOverrides.${y}
        else y
      )
  );
in
{
  config = mkMerge ([
    (mkIf (cfg.master.hostname == hostName) {
      services.loki.enable = true;
      networking.firewall.allowedTCPPorts = [ 3100 ];
      services.loki.configFile = pkgs.writeText "loki.yml" ''
        auth_enabled: false
        server:
          http_listen_port: 3100
          grpc_listen_port: 9096
        
        ingester:
          wal:
            enabled: true
            dir: /tmp/wal
          lifecycler:
            address: 127.0.0.1
            ring:
              kvstore:
                store: inmemory
              replication_factor: 1
            final_sleep: 0s
          chunk_idle_period: 1h       # Any chunk not receiving new logs in this time will be flushed
          max_chunk_age: 1h           # All chunks will be flushed when they hit this age, default is 1h
          chunk_target_size: 1048576  # Loki will attempt to build chunks up to 1.5MB, flushing first if chunk_idle_period or max_chunk_age is reached first
          chunk_retain_period: 30s    # Must be greater than index read cache TTL if using an index cache (Default index read cache TTL is 5m)
          max_transfer_retries: 0     # Chunk transfers disabled
        
        schema_config:
          configs:
            - from: 2020-10-24
              store: boltdb-shipper
              object_store: filesystem
              schema: v11
              index:
                prefix: index_
                period: 24h
        
        storage_config:
          boltdb_shipper:
            active_index_directory: /tmp/loki/boltdb-shipper-active
            cache_location: /tmp/loki/boltdb-shipper-cache
            cache_ttl: 24h         # Can be increased for faster performance over longer query periods, uses more disk space
            shared_store: filesystem
          filesystem:
            directory: /tmp/loki/chunks
        
        compactor:
          working_directory: /tmp/loki/boltdb-shipper-compactor
          shared_store: filesystem
        
        limits_config:
          reject_old_samples: true
          reject_old_samples_max_age: 168h
        
        chunk_store_config:
          max_look_back_period: 0s
        
        table_manager:
          retention_deletes_enabled: false
          retention_period: 0s
        
        ruler:
          storage:
            type: local
            local:
              directory: /tmp/loki/rules
          rule_path: /tmp/loki/rules-temp
          alertmanager_url: http://localhost:9093
          ring:
            kvstore:
              store: inmemory
          enable_api: true
      '';
      services.prometheus = {
        enable = true;
        scrapeConfigs = foldl (a: b: a ++ b) [ ] (map
          (x: (map
            (y: {
              job_name = "${x}_${y}";
              static_configs = [
                {
                  targets = [
                    ''${getHost y}:${toString config.services.prometheus.exporters.${x}.port}''
                  ];
                }
              ];
            })
            cfg.exporters.${x}.hosts))
          (builtins.attrNames cfg.exporters));
      };
      ragon.persist.extraDirectories = [
        "/var/lib/${config.services.prometheus.stateDir}"
        "${config.services.loki.dataDir}"
      ];
    })
    {
      # some global settings
      services.prometheus.exporters.node.enabledCollectors = [ "systemd" ];
      services.prometheus.exporters.dnsmasq.leasesPath = "/var/lib/dnsmasq/dnsmasq.leases";
      systemd.services."prometheus-smartctl-exporter".serviceConfig.DeviceAllow = [ "* r" ];
      services.prometheus.exporters.smartctl.user = "root";
      services.prometheus.exporters.smartctl.group = "root";
      services.prometheus.exporters.smokeping.hosts = [ "1.1.1.1" ];
      services.nginx.statusPage = mkDefault config.services.prometheus.exporters.nginx.enable;
      services.prometheus.exporters.nginxlog.user = "nginx";
      services.prometheus.exporters.nginxlog.group = "nginx";
      services.prometheus.exporters.nginxlog.settings = {
        namespaces = [{
          name = "nginxlog";
          format = "$remote_addr - - [$time_local] \"$request\" $status $body_bytes_sent \"$http_referer\" \"$http_user_agent\"";
          source.files = [ "/var/log/nginx/access.log" ];
        }];
      };
    }
    (mkIf (builtins.elem hostName cfg.promtail.hosts) {
      services.promtail = {
        enable = true;
        configuration = {
          server.http_listen_port = 28183;
          positions.filename = "/tmp/positions.yaml";
          clients = [{ url = "http://${cfg.master.ip}:3100/loki/api/v1/push"; }];
          scrape_configs = [
            {
              job_name = "journal";
              journal = {
                max_age = "12h";
                labels = {
                  job = "systemd-journal";
                  host = hostName;
                };
              };
              relabel_configs = [{
                source_labels = [ "__journal__systemd_unit" ];
                target_label = "unit";
              }];
            }
          ];
        };
      };

    })
  ] ++
  (map
    (x: {
      services.prometheus.exporters.${x} = {
        enable = (builtins.elem hostName cfg.exporters.${x}.hosts);
        #openFirewall = (hostName != cfg.master.hostname);
        #firewallFilter = if (hostName != cfg.master.hostname) then "-p tcp -s ${cfg.master.ip} -m tcp --dport ${toString config.services.prometheus.exporters.${x}.port}" else null;
      };
    })
    (builtins.attrNames cfg.exporters))
  );

}

