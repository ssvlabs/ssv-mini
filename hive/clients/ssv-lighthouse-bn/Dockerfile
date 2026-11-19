# Lighthouse bn for the ssv simulator. hive's own lighthouse-bn scripts target an older CLI
# (--execution-endpoints, --jwt-secrets, valued boolean flags), so this one is kept minimal and current.
ARG baseimage=sigp/lighthouse
ARG tag=latest
FROM $baseimage:$tag

ADD lighthouse_bn.sh /lighthouse_bn.sh
RUN chmod +x /lighthouse_bn.sh
RUN lighthouse --version | head -1 | sed "s/ /\//g" > /version.txt

ENTRYPOINT ["/lighthouse_bn.sh"]
