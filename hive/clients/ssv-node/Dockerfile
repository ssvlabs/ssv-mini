# SSV node as a hive client. Built on a local ssv image (make prepare-ssv / docker build -t node/ssv:<tag>).
ARG baseimage=node/ssv
ARG tag=latest
FROM $baseimage:$tag

ADD ssv.sh /ssv.sh
RUN chmod +x /ssv.sh
RUN /go/bin/ssvnode version 2>/dev/null | head -1 > /version.txt || echo unknown > /version.txt

ENTRYPOINT ["/ssv.sh"]
