FROM nginx:alpine

RUN apk add --no-cache curl openssl

COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /docker-entrypoint.d/50-nomad-certs.sh
RUN chmod +x /docker-entrypoint.d/50-nomad-certs.sh
COPY html /usr/share/nginx/html

# Vendor MapLibre + PMTiles protocol at build time so runtime is fully offline.
# Pin versions — bump deliberately.
RUN set -eux; \
    mkdir -p /usr/share/nginx/html/vendor; \
    cd /usr/share/nginx/html/vendor; \
    curl -fsSL -o maplibre-gl.js       https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.js; \
    curl -fsSL -o maplibre-gl.css      https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.css; \
    curl -fsSL -o pmtiles.js           https://unpkg.com/pmtiles@3.2.1/dist/pmtiles.js; \
    curl -fsSL -o openlocationcode.js  https://unpkg.com/open-location-code@1.0.3/openlocationcode.js; \
    curl -fsSL -o mgrs.js              https://unpkg.com/mgrs@2.1.0/dist/mgrs.min.js
