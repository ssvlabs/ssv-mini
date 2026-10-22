# Throwaway geth --dev the ssv simulator uses to pre-mine the devnet's EL history (the SSV registrations plus
# the follow-distance padding) seconds before the real network starts. See simulators/ssv/premine.go.
ARG baseimage=ethereum/client-go
ARG tag=latest
FROM $baseimage:$tag

ADD premine.sh /premine.sh
RUN chmod +x /premine.sh
RUN geth version | grep '^Version' | sed 's/Version: /Geth\//' > /version.txt

ENTRYPOINT ["/premine.sh"]
