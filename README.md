# My Arch User Repository

This project periodically builds several packages that are not in AUR and several packages from AUR.
The aim is to build them automatically and publish to my repository so we don't have to re-build them often manually on every single arch-powered-device we own.

We use GitHub actions to build the packages and create a local repository (which we publish as an CI artifact) and then transfer the artifacts to our server where the repository lives.

The project always rebuilds all packages.
