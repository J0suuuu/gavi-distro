# gavi_burger

Your distro kit from linuxlive.com: the spec that describes gavi_burger
and its art.

    linuxlive.yaml          the spec
    assets/                 wallpaper and logo
    scripts/                your scripts (build, first-boot, first-login)

Your scripts run as root: while the image is built, at
the first start of an installed system, or at each user's first login. Read
them through before you share the distro; the Library reviews every line.

## Build it in your own GitHub (no Linux needed)

1. Open https://github.com/Eric-Ness/linuxlive-distro, click "Use this
   template", then "Create a new repository". Keep it public: builds are
   free and the ISO can be downloaded.
2. In your new repository choose "Add file", then "Upload files", and drop
   in everything from this kit except this README (linuxlive.yaml and its
   folders). They replace the template's example. Commit.
3. Open the Actions tab. The build takes about 20 minutes for Ubuntu and 40
   for Fedora; it boots the ISO five ways and checks it against your spec.
4. Open the finished run and download "iso-gavi-burger" under Artifacts: a zip
   with gavi-burger.iso and its checksum.

## Or build it on your own Linux machine

Building locally needs root, podman, QEMU and a few ISO tools; see
https://docs.linuxlive.com/spec/building-locally/ for the full list.

    git clone https://github.com/Eric-Ness/linuxlive
    cd linuxlive
    python -m pip install -r requirements.txt
    python -m linuxlive validate ../gavi-burger/linuxlive.yaml
    python -m linuxlive compile ../gavi-burger/linuxlive.yaml -o build/ctx
    sudo podman build -t localhost/gavi-burger build/ctx
    sudo bash scripts/assemble-iso.sh build/ctx localhost/gavi-burger build/gavi-burger.iso

## Then boot it

Put the ISO on a USB stick and start a PC from it: https://linuxlive.com/learn/
If something goes wrong: https://docs.linuxlive.com/help/failed-builds/

## Show where it came from

Paste this into your repository's README for a "Built with linuxlive" badge:

    [![Built with linuxlive](https://linuxlive.com/badge.svg)](https://linuxlive.com/)
