{pkgs ? import <nixpkgs> {}}: {
  url,
  directory ? null,
  filename,
  hash,
  recursiveHash ? false,
  postFetch ? "",
  downloadToTemp ? false,
  executable ? false,
  nativeBuildInputs ? [],
  varPrefix ? null,
  ...
}: let
  name = filename;

  varBase = "NIX${pkgs.lib.optionalString (varPrefix != null) "_${varPrefix}"}_FETCHSMB_";

  impureEnvVars =
    pkgs.lib.fetchers.proxyImpureEnvVars
    # smbclient does not use netrc, afaict
    ++ [
      "${varBase}USERNAME"
      "${varBase}PASSWORD"
      "${varBase}DOMAIN"
    ];

  postFetchScript = pkgs.writeShellScript "postFetch.sh" ''
    echo "Need to manually source stdenv setup for this to work..."
    . ${pkgs.stdenvNoCC}/setup
    echo "running postFetch..."
    ${postFetch}
  '';

  # bash gives me sadbrains, so using nushell instead
  builderScript = pkgs.writers.writeNu "fetchsmbclient.nu" ''
    # debugging
    $env | to text | print

    let conf = $"[global]\nclient min protocol = CORE\n";
    $conf | save --raw smb.conf

    let authenticationFile = "authenticationFile.txt"
    $"username = ($env.varBase)USERNAME\n" | save --raw $authenticationFile
    $"password = ($env.varBase)PASSWORD\n" | save --raw --append $authenticationFile
    $"domain = ($env.varBase)DOMAIN\n" | save --raw --append $authenticationFile

    # I'm putting the args in an array where each arg is a single string,
    # so that args are passed/escaped properly to smbclient.
    let args = [
      "${url}",
      "--configfile=smb.conf",
      (if "${directory}" != "" {"--directory"} else {""}),
      (if "${directory}" != "" {"${directory}"} else {""}),
      "--authentication-file",
      $authenticationFile,
      "--command",
      "get ${filename} ${filename}"
    ]

    # for debugging
    $args | to text | print

    ${pkgs.samba}/bin/smbclient ...$args

    if ($env.executable == "1") {
      print "setting executable bit on ${filename}"
      chmod +x ${filename}
    }

    if ($env.downloadToTemp == "1") {
      let src = (${pkgs.coreutils}/bin/realpath ${filename})
      let dst = (${pkgs.coreutils}/bin/realpath ($env.TMPDIR + "/" + ${filename}))
      if ($src != $dst) {
        print $"moving ${filename} to ($env.TMPDIR)"
        mv ${filename} ($env.TMPDIR + "/" + ${filename})
      } else {
        print "keeping ${filename} in place"
      }

      $env.downloadedFile = $dst
    } else {
      print "moving ${filename} to $env.out"
      mv ${filename} $env.out

      $env.downloadedFile = ($env.out + "/" + ${filename})
    }

    # For debugging
    # Important! Load-bearing environment variable!
    # https://github.com/NixOS/nixpkgs/blob/25.05/pkgs/build-support/fetchurl/default.nix#L99-L101
    $env.downloadedFile | to text | print

    exec ${postFetchScript}
  '';
in
  pkgs.stdenvNoCC.mkDerivation {
    inherit name postFetch downloadToTemp executable impureEnvVars;
    inherit (pkgs.stdenvNoCC.buildPlatform) system;

    outputHashMode =
      if (recursiveHash || executable)
      then "recursive"
      else "flat";

    nativeBuildInputs =
      [
        pkgs.samba
        pkgs.nushell
      ]
      ++ nativeBuildInputs;

    outputHash = hash;

    builder = pkgs.writeShellScript "builder.sh" ''
      . ${pkgs.stdenvNoCC}/setup
      "${builderScript}"
    '';
  }
