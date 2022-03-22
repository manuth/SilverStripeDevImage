#!/bin/bash
outputPath=/tmp/test-output
apache2-foreground &
su www-data -s /bin/bash -c "composer create-project -n silverstripe/installer:4.10.0 ."
wget -O $outputPath --content-on-error localhost
! cat $outputPath | grep -i "deprecated"
