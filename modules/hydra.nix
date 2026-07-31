{
  pkgs,
  ...
}:

let
  hostName = "hydra.nixos.lv";
  runnerHostName = "runner.${hostName}";
in
{
  services.nginx = {
    upstreams.hydra.servers."[::1]:3000".backup = false;
    virtualHosts = {
      ${hostName} = {
        forceSSL = true;
        enableACME = true;
        locations."/" = {
          proxyPass = "http://hydra";
          extraConfig = ''
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_max_temp_file_size 0;
          '';
        };
      };
      ${runnerHostName} = {
        forceSSL = true;
        enableACME = true;
        locations."/".extraConfig =
          let
            timeout = "${toString (24 * 60 * 60)}s";
          in
          ''
            # https://stackoverflow.com/a/67805465
            client_body_timeout ${timeout};
            client_max_body_size 0;

            grpc_pass grpc://[::1]:50051;
            grpc_read_timeout ${timeout};
            grpc_send_timeout ${timeout};
            grpc_socket_keepalive on;

            grpc_set_header Host $host;
            grpc_set_header X-Real-IP $remote_addr;
            grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            grpc_set_header X-Forwarded-Proto $scheme;
            grpc_set_header X-Client-DN $ssl_client_s_dn;
            grpc_set_header X-Client-Cert $ssl_client_escaped_cert;
          '';
        extraConfig = ''
          ssl_client_certificate ${pkgs.nixos-lv-root-ca};
          ssl_verify_depth 2;
          ssl_verify_client on;
        '';
      };
    };
  };

  services.hydra-dev = {
    enable = true;
    hydraURL = "https://${hostName}";
    notificationSender = "noreply@nix.vegas";
    smtpHost = "mail.nix.vegas";
    useSubstitutes = true;
    extraConfig = ''
      max_servers 4
      <Plugin::Session>
        cache_size = 16m
      </Plugin::Session>
      evaluator_workers = 4
      # Full nixpkgs release.nix eval across ALL supportedSystems (linux x2 +
      # darwin x2 + 32-bit/arm variants) is the heaviest eval nixpkgs has and
      # peaks well past 8G; 2048 OOM-kills the evaluator before it finishes.
      # NB: this is a per-evaluator cap -- with max_concurrent_evals = 2 the
      # worst case is 2x this. ghostgate caps ZFS ARC at 4G, so if the box OOMs
      # on a concurrent nixpkgs+other eval, drop max_concurrent_evals to 1
      # rather than lowering this (a truncated nixpkgs eval is useless).
      evaluator_max_memory_size = 4096
      queue_runner_endpoint = http://localhost:8080
      upload_logs_to_binary_cache = true

      store_uri = local
      binary_cache_public_uri = https://cache.nixos.lv

      compress_build_logs = true
      max_concurrent_evals = 5
      max_unsupported_time = 86400

      max_output_size = ${toString (1024 * 1024 * 1024)}
      allow_import_from_derivation = false
    '';
  };

  services.hydra-queue-runner-dev = {
    enable = true;
    settings = {
      queueTriggerTimerInS = 300;
      concurrentUploadLimit = 2;
    };
  };

  services.postgresql.settings = {
    log_min_duration_statement = 5000;
    log_duration = "off";
    log_statement = "none";
    max_connections = 256;
    work_mem = "20MB";
    maintenance_work_mem = "2GB";
  };
}
