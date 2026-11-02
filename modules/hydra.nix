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
      # Eval memory budget. These two keys are read by hydra-eval-jobset (Perl)
      # and passed to nix-eval-jobs as --workers / --max-memory-size; they are
      # NOT part of the Rust hydra-evaluator's toml (only max_concurrent_evals
      # is -- see services.hydra-evaluator-dev.settings below).
      #
      # Full nixpkgs release.nix eval across ALL supportedSystems (linux x2 +
      # darwin x2 + 32-bit/arm variants) is the heaviest eval nixpkgs has and
      # peaks well past 8G; 2048 OOM-kills the evaluator before it finishes, so
      # max_memory_size stays at 4096 (a truncated nixpkgs eval is useless).
      # Worst-case eval RSS ~= max_concurrent_evals * evaluator_workers *
      # per-worker peak (4G restart threshold, ~8G on the heaviest attr).
      # 2 evals * 3 workers ~= 24G typical on this 62G box (ZFS ARC capped at
      # 4G); the MemoryMax fence on hydra-evaluator-dev (below) catches the
      # theoretical extreme so a runaway eval fails instead of OOMing the host.
      # If evals get fenced too often, drop max_concurrent_evals to 1 before
      # lowering workers or this cap.
      evaluator_workers = 3
      evaluator_max_memory_size = 4096
      queue_runner_endpoint = http://localhost:8080
      upload_logs_to_binary_cache = true

      binary_cache_public_uri = https://cache.nixos.lv

      compress_build_logs = true
      # max_concurrent_evals is NOT read from hydra.conf by the Rust evaluator;
      # it lives in services.hydra-evaluator-dev.settings (below).
      max_unsupported_time = 86400

      max_output_size = ${toString (1024 * 1024 * 1024)}
      # Let jobsets import-from-derivation. Eval-time builds run through the
      # evaluator's nix (offloading to citadel via /etc/nix/machines like any
      # build), so they add eval time/memory but not a new build path. If IFD
      # evals start OOMing, lower max_concurrent_evals before touching
      # evaluator_max_memory_size (see above).
      allow_import_from_derivation = true
    '';
  };

  # The Rust hydra-evaluator reads ONLY this toml for concurrency; the
  # hydra.conf value is ignored (it was silently running the module default
  # of 4, i.e. up to 4 evals * 4 workers * 4G+ -- the likely source of the
  # OOM history on this box).
  services.hydra-evaluator-dev.settings.max_concurrent_evals = 2;

  # Cgroup fence for the evaluator and the hydra-eval-jobset / nix-eval-jobs
  # children it spawns: a runaway eval is OOM-killed inside this cgroup (that
  # eval fails and is retried) rather than taking the host down. Sized above
  # the ~24G typical worst case of 2 evals * 3 workers, leaving ~26G for ARC
  # (4G), the queue-runner, forgejo, home-assistant and nebula.
  systemd.services.hydra-evaluator-dev.serviceConfig.MemoryMax = "36G";

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
