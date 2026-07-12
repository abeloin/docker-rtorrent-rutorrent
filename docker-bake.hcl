variable "DEFAULT_TAG" {
  default = "rtorrent-rutorrent:local"
}

// Alpine PHP version to build against (e.g. "84", "85").
// Empty string falls back to the Dockerfile's ARG default.
variable "ALPINE_PHP_VERSION" {
  default = ""
}

// Special target: https://github.com/docker/metadata-action#bake-definition
target "docker-metadata-action" {
  tags = ["${DEFAULT_TAG}"]
}

// Default target if none specified
group "default" {
  targets = ["image-local"]
}

target "image" {
  inherits = ["docker-metadata-action"]
  args = {
    // Only override the Dockerfile ARG default when a version is provided.
    ALPINE_PHP_VERSION = notequal("", ALPINE_PHP_VERSION) ? ALPINE_PHP_VERSION : null
  }
}

target "image-local" {
  inherits = ["image"]
  output = ["type=docker"]
}

target "image-all" {
  inherits = ["image"]
  platforms = [
    "linux/amd64",
    "linux/arm/v6",
    "linux/arm/v7",
    "linux/arm64"
  ]
}

target "geoip2-rutorrent-vendor" {
  target = "export-geoip2-rutorrent"
  output = ["type=local,dest=geoip2-rutorrent"]
}
