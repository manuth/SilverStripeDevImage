# SilverStripeDevImage
A docker-image for developing and building SilverStripe components and websites.

## General
In order to develop, test and run SilverStripe-components with comfort
you need to have a couple dependencies installed, such as composer, npm, php, a bunch of php-extension and much more.

This docker-image provides all said components and
allows you to easily create, install and test, build or publish SilverStripe-components.

## How to Use?
Pull the image using the following command:

```sh
docker run manuth/silverstripe-dev -it -v $(pwd):/var/www/html
```

## Volumes
This image expects the content of the SilverStripe website to be located at `/var/www/html`. You might want to mount your website to this directory.
