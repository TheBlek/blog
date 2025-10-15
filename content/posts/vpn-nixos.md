+++
date = '2025-10-15T16:20:34+07:00'
draft = false
title = 'Setting up vless vpn on nixos (via v2rayA)'
+++

I've tried setting up vpn on nixos a couple of times over the past year. And each time it did not work in different ways. Today I finally made it work. For myself and others I will leave solution here. 

v2rayA/v2ray/... must **not** be in packages. This will not work and may interfere with correct installation.
# v2rayA service
Put this line into your `configuration.nix`
```
services.v2raya.enable = true;
```
Rebuild, go to `localhost:2017`, add your subscription or configure vpn, run

That's all basically :)

I had a couple of problems with it.

if v2raya asks you to login, but you do not remember registering or forgot credentials, reset password:
```
sudo systemctl stop v2raya.service
sudo v2rayA --reset-password
sudo systemctl start v2raya.service
```
If after importing your subscription and enabling proxying you get PR_END_OF_FILE_ERROR in firefox-based browsers and ERR_CONNECTION_TIMED_OUT in chromium-based browsers, you might need to change the *core* from v2ray to xray.
Add this to `configuration.nix`:
```
services.v2raya.cliPackage = pkgs.xray;
```
This option was only released in nixpkgs 25.05. 
If your nixpkgs are older, you could upgrade or install v2rayA service from another channel.
To install from another channel put this into `configuration.nix`
```
  # TODO: remove after upgrading to 25.11
  disabledModules = ["services/networking/v2raya.nix"];

  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      <nixos-unstable/nixos/modules/services/networking/v2raya.nix>
    ];
```
`hardware-configuration.nix` should be in imports by default, no need to touch it.

If you had any other problems with setting up and managed to solve them - feel free to shoot me an email to add to this article. 

# Sources
Service reference: https://www.reddit.com/r/NixOS/comments/1jnxs1m/v2ray_client_on_nixos/

PR_END_OF_FILE_ERROR solution: https://github.com/v2rayA/v2rayA/discussions/1588#discussioncomment-13107884

PR to add cliPackage: https://github.com/NixOS/nixpkgs/pull/334876

Setting service with a custom channel: https://nixos.org/manual/nixos/unstable/#sec-replace-modules
