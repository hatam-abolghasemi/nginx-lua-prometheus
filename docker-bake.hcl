variable "RESTY_VERSION" {
  default = ""
}

variable "UPSTREAM_TAG" {
  default = ""
}

variable "RESTY_J" {
  default = "4"
}

variable "TAGS" {
  default = "openresty-prometheus:local"
}

variable "GIT_SHA" {
  default = ""
}

target "openresty-base" {
  context    = "docker-openresty"
  dockerfile = "alpine/Dockerfile"
  args = {
    RESTY_VERSION = RESTY_VERSION
    RESTY_J       = RESTY_J
  }
}

target "image" {
  context    = "."
  dockerfile = "docker/Dockerfile"
  contexts = {
    openresty-base = "target:openresty-base"
  }
  tags = split(",", TAGS)
  labels = {
    "org.opencontainers.image.source"      = "https://github.com/hatam-abolghasemi/nginx-lua-prometheus"
    "org.opencontainers.image.revision"    = GIT_SHA
    "org.opencontainers.image.version"     = UPSTREAM_TAG
    "org.opencontainers.image.description" = "OpenResty ${RESTY_VERSION} with nginx-lua-prometheus and the sidecar lib/ modules baked in"
  }
}

group "default" {
  targets = ["image"]
}
