FROM xfreex/avnav-daily:20260709

# Rebuilt for ARM64 with a longer oexserverd startup wait.  On HALPI2 the
# upstream provider can otherwise stop after five seconds while oexserverd is
# still initializing, leaving Traefik with a dead port 8083 backend.
# Use the provider from the ARM64 base image. It is packaged and tested
# together with the bundled SG-Lock/oexserverd libraries. The locally rebuilt
# provider is retained in the build context for comparison, but is not used
# for this validation image.
COPY ochartsng/AvnavOchartsProvider.base /usr/lib/avnav/plugins/ochartsng/AvnavOchartsProvider
COPY ochartsng/libpreload.so /usr/lib/avnav/plugins/ochartsng/libpreload.so
COPY ochartsng/oexserverd /usr/lib/avnav/plugins/ochartsng/oexserverd

# The upstream plugin registers its user-app as HTTP on provider port 8083.
# HaLOS serves AvNav through HTTPS, so Chromium blocks that URL as mixed active
# content. The provider is routed through /ocharts/ by the Compose labels.
RUN sed -i \
    -e 's#^    appUrl=.*$#    appUrl="https://\$HOST:4431/ocharts/static/index.html"#' \
    /usr/lib/avnav/plugins/ochartsng/plugin.py && \
    sed -i \
    -e 's#item\[k\]=item\[k\]\.replace("localhost",hostip)\.replace("127\.0\.0\.1",hostip)#item[k]=re.sub(r"https?://[^/]+:8083", "/ocharts", item[k])#' \
    /usr/lib/avnav/plugins/ochartsng/plugin.py && \
    sed -i \
    -e 's#addonhandler.registerAddOn(self.USERAPP_NAME,"http://%s:%s" %#addonhandler.registerAddOn(self.USERAPP_NAME,"https://\$HOST:4430" if self.config.skHost == "host.docker.internal" else "http://%s:%s" %#' \
    /usr/lib/avnav/server/handler/signalkhandler.py && \
    sed -i \
    -e 's#"/charts/#"/ocharts/charts/#g' \
    -e 's#"/download#"/ocharts/download#g' \
    -e 's#"/list?item=#"/ocharts/list?item=#g' \
    -e 's#"/settings/#"/ocharts/settings/#g' \
    -e 's#"/shop/#"/ocharts/shop/#g' \
    -e 's#"/status/#"/ocharts/status/#g' \
    -e 's#"/upload/#"/ocharts/upload/#g' \
    /usr/lib/avnav/plugins/ochartsng/gui/index.js && \
    sed -i \
    -e 's#t="ws://"+window.location.host#t=(window.location.protocol==="https:"?"wss://":"ws://")+window.location.host#' \
    /usr/lib/avnav/viewer/avnav_min.js
