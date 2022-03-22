#!/bin/bash
apache2-foreground &
su www-data -s /bin/bash -c "composer create-project -n silverstripe/installer:4.10.0 ."
wget -O /tmp/test-output --content-on-error localhost
! cat /tmp/test-output | grep -i "deprecated"
