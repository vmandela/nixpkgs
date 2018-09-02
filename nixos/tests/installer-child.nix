{ system ? builtins.currentSystem }:

with import ../lib/testing.nix { inherit system; };
with pkgs.lib;

let

  # The configuration to install.
  makeConfig = { bootLoader, grubVersion, grubDevice, grubIdentifier, grubUseEfi
               , extraConfig, forceGrubReinstallCount ? 0
               }:
    pkgs.writeText "configuration.nix" ''
      { config, lib, pkgs, modulesPath, ... }:

      { imports =
          [ ./hardware-configuration.nix
            <nixpkgs/nixos/modules/testing/test-instrumentation.nix>
          ];

        # To ensure that we can rebuild the grub configuration on the nixos-rebuild
        system.extraDependencies = with pkgs; [ stdenvNoCC ];

        ${optionalString (bootLoader == "grub") ''
          boot.loader.grub.version = ${toString grubVersion};
          ${optionalString (grubVersion == 1) ''
            boot.loader.grub.splashImage = null;
          ''}

          boot.loader.grub.extraConfig = "serial; terminal_output.serial";
          ${if grubUseEfi then ''
            boot.loader.grub.device = "nodev";
            boot.loader.grub.efiSupport = true;
            boot.loader.grub.efiInstallAsRemovable = true; # XXX: needed for OVMF?
          '' else ''
            boot.loader.grub.device = "${grubDevice}";
            boot.loader.grub.fsIdentifier = "${grubIdentifier}";
          ''}

          boot.loader.grub.configurationLimit = 100 + ${toString forceGrubReinstallCount};
        ''}

        ${optionalString (bootLoader == "systemd-boot") ''
          boot.loader.systemd-boot.enable = true;
        ''}

        users.users.alice = {
          isNormalUser = true;
          home = "/home/alice";
          description = "Alice Foobar";
        };

        hardware.enableAllFirmware = lib.mkForce false;

        services.udisks2.enable = lib.mkDefault false;

        ${replaceChars ["\n"] ["\n  "] extraConfig}
      }
    '';


  # This test is derived from the basic configuration of the installer
  # test.The test script boots a NixOS VM, installs NixOS on an empty hard
  # disk. The NixOS configuration has two configurations.
  #
  # - Default configuration
  # - Work configuration - This has an extra "/etc/gitconfig" file.
  #
  #  Once the VM is setup,
  # - reboot and verify that it has booted into default configuration.
  # - Reboot into the "Work" configuration via grub.
  # - Verify that we have booted into the "Work" configuration and that
  # the extra config file is present.

  testScriptFun = { bootLoader, createPartitions, grubVersion, grubDevice, grubUseEfi
                  , grubIdentifier, preBootCommands, extraConfig
                  }:
    let
      iface = if grubVersion == 1 then "ide" else "virtio";
      isEfi = bootLoader == "systemd-boot" || (bootLoader == "grub" && grubUseEfi);

      # FIXME don't duplicate the -enable-kvm etc. flags here yet again!
      qemuFlags =
        (if system == "x86_64-linux" then "-m 768 " else "-m 512 ") +
        (optionalString (system == "x86_64-linux") "-cpu kvm64 ") +
        (optionalString (system == "aarch64-linux") "-enable-kvm -machine virt,gic-version=host -cpu host ");

      hdFlags = ''hda => "vm-state-machine/machine.qcow2", hdaInterface => "${iface}", ''
        + optionalString isEfi (if pkgs.stdenv.isAarch64
            then ''bios => "${pkgs.OVMF.fd}/FV/QEMU_EFI.fd", ''
            else ''bios => "${pkgs.OVMF.fd}/FV/OVMF.fd", '');
    in if !isEfi && !(pkgs.stdenv.isi686 || pkgs.stdenv.isx86_64) then
      throw "Non-EFI boot methods are only supported on i686 / x86_64"
    else ''
      $machine->start;

      # Make sure that we get a login prompt etc.
      $machine->succeed("echo hello");
      #$machine->waitForUnit('getty@tty2');
      #$machine->waitForUnit("rogue");
      $machine->waitForUnit("nixos-manual");

      # Wait for hard disks to appear in /dev
      $machine->succeed("udevadm settle");

      # Partition the disk.
      ${createPartitions}

      # Create the NixOS configuration.
      $machine->succeed("nixos-generate-config --root /mnt");

      $machine->succeed("cat /mnt/etc/nixos/hardware-configuration.nix >&2");

      $machine->copyFileFromHost(
          "${ makeConfig { inherit bootLoader grubVersion grubDevice grubIdentifier grubUseEfi extraConfig; } }",
          "/mnt/etc/nixos/configuration.nix");

      # Perform the installation.
      $machine->succeed("nixos-install < /dev/null >&2");

      $machine->succeed("umount /mnt/boot || true");
      $machine->succeed("umount /mnt");
      $machine->succeed("sync");

      $machine->shutdown;

      # Reboot Machine
      $machine = createMachine({ ${hdFlags} qemuFlags => "${qemuFlags}", name => "boot-after-install" });
      $machine->waitForUnit("multi-user.target");

      # Booted configuration name should be Default
      $machine->succeed("cat /run/booted-system/configuration-name >&2");
      $machine->succeed("cat /run/booted-system/configuration-name | grep Default");

      # We should find **not** a file named /etc/gitconfig
      $machine->fail("test -e /etc/gitconfig");

      # Set grub to boot the second configuration
      $machine->succeed("sudo grub-reboot 1");

      $machine->shutdown;

      # Reboot Machine
      $machine = createMachine({ ${hdFlags} qemuFlags => "${qemuFlags}", name => "boot-after-install" });

      $machine->waitForUnit("multi-user.target");
      # Booted configuration name should be Work
      $machine->succeed("cat /run/booted-system/configuration-name >&2");
      $machine->succeed("cat /run/booted-system/configuration-name | grep Work");

      # We should find a file named /etc/gitconfig
      $machine->succeed("test -e /etc/gitconfig");

      $machine->shutdown;

    '';


  makeInstallerTest = name:
    { createPartitions, preBootCommands ? "", extraConfig ? ""
    , extraInstallerConfig ? {}
    , bootLoader ? "grub" # either "grub" or "systemd-boot"
    , grubVersion ? 2, grubDevice ? "/dev/vda", grubIdentifier ? "uuid", grubUseEfi ? false
    , enableOCR ? false, meta ? {}
    }:
    makeTest {
      inherit enableOCR;
      name = "installer-" + name;
      meta = with pkgs.stdenv.lib.maintainers; {
        # put global maintainers here, individuals go into makeInstallerTest fkt call
        maintainers = [ wkennington ] ++ (meta.maintainers or []);
      };
      nodes = {

        # The configuration of the machine used to run "nixos-install".
        machine =
          { pkgs, ... }:

          { imports =
              [ ../modules/profiles/installation-device.nix
                ../modules/profiles/base.nix
                extraInstallerConfig
              ];

            virtualisation.diskSize = 8 * 1024;
            virtualisation.memorySize = 1024;

            # Use a small /dev/vdb as the root disk for the
            # installer. This ensures the target disk (/dev/vda) is
            # the same during and after installation.
            virtualisation.emptyDiskImages = [ 512 ];
            virtualisation.bootDevice =
              if grubVersion == 1 then "/dev/sdb" else "/dev/vdb";
            virtualisation.qemu.diskInterface =
              if grubVersion == 1 then "scsi" else "virtio";

            boot.loader.systemd-boot.enable = mkIf (bootLoader == "systemd-boot") true;

            hardware.enableAllFirmware = mkForce false;

            # The test cannot access the network, so any packages we
            # need must be included in the VM.
            system.extraDependencies = with pkgs;
              [ sudo
                libxml2.bin
                libxslt.bin
                docbook5
                docbook_xsl_ns
                unionfs-fuse
                ntp
                nixos-artwork.wallpapers.gnome-dark
                perlPackages.XMLLibXML
                perlPackages.ListCompare
                xorg.lndir

                # add curl so that rather than seeing the test attempt to download
                # curl's tarball, we see what it's trying to download
                curl
              ]
              ++ optional (bootLoader == "grub" && grubVersion == 1) pkgs.grub
              ++ optionals (bootLoader == "grub" && grubVersion == 2) [ pkgs.grub2 pkgs.grub2_efi ];

            services.udisks2.enable = mkDefault false;

            nix.binaryCaches = mkForce [ ];
            nix.extraOptions =
              ''
                hashed-mirrors =
                connect-timeout = 1
              '';
          };

      };

      testScript = testScriptFun {
        inherit bootLoader createPartitions preBootCommands
                grubVersion grubDevice grubIdentifier grubUseEfi extraConfig;
      };
    };


in {

  # !!! `parted mkpart' seems to silently create overlapping partitions.


  # The (almost) simplest partitioning scheme: a swap partition and
  # one big filesystem partition.
  simple = makeInstallerTest "simple"
    { createPartitions =
        ''
          $machine->succeed(
              "parted --script /dev/vda mklabel msdos",
              "parted --script /dev/vda -- mkpart primary linux-swap 1M 1024M",
              "parted --script /dev/vda -- mkpart primary ext2 1024M -1s",
              "udevadm settle",
              "mkswap /dev/vda1 -L swap",
              "swapon -L swap",
              "mkfs.ext3 -L nixos /dev/vda2",
              "mount LABEL=nixos /mnt",
          );
        '';
        bootLoader = "grub";
        grubVersion = 2;

        # Set unique configuration names for the two configurations.
        # Create an extra file for the "Work" configuration
        extraConfig =
          ''
          boot.loader.grub.configurationName = "Default";
          nesting.clone = [
          {
            boot.loader.grub.configurationName = lib.mkForce "Work";

            environment.etc = {
              "gitconfig".text = "
                [core]
                  gitproxy = none for work.com
                  ";
            };
          }
          ];
          '';
    };

}
