#!/bin/sh
# Undoes what install.sh set up. It does not remove the project's folder or its work. Apprentice never runs this by
# itself: you do, with Uninstall on the project's Settings or `apprentice project uninstall`. In a project with a VM it
# runs there, like install.sh.
set -e
