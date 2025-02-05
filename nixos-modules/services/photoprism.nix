{ config, lib, pkgs, ... }:
with lib;
with lib.my;
let
  cfg = config.ragon.services.photoprism;
  domain = config.ragon.services.nginx.domain;
in
{
  options.ragon.services.photoprism.enable = mkEnableOption "Enables the hedgedoc BitWarden Server";
  options.ragon.services.photoprism.domainPrefix =
    mkOption {
      type = lib.types.str;
      default = "photos";
    };
  options.ragon.services.photoprism.port =
    mkOption {
      type = lib.types.str;
      default = "28452";
    };
  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers.containers.photoprism = {
      ports = [ "127.0.0.1:${cfg.port}:2342" ];
      image = "photoprism/photoprism:latest";
      environmentFiles = [ config.age.secrets.photoprismEnv.path ];
      workdir = "/photoprism"; # upstream says so
      user = "1000:100";
      volumes = [
        "/data/pictures:/photoprism/originals"
        "/data/applications/photoprismimport:/photoprism/import"
        "/var/lib/photoprism:/photoprism/storage"
      ];
    };
    ragon.agenix.secrets.photoprismEnv.owner = "root";
    services.nginx.virtualHosts."${cfg.domainPrefix}.${domain}" = {
      forceSSL = true;
      useACMEHost = "${domain}";
      locations."/".proxyWebsockets = true;
      locations."/".proxyPass = "http://127.0.0.1:${cfg.port}";
    };
    ragon.persist.extraDirectories = [
      "/var/lib/photoprism"
    ];
  };
}
