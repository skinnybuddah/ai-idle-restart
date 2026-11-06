FROM docker:latest
COPY monitor.sh /monitor.sh
RUN chmod +x /monitor.sh
ENTRYPOINT ["/bin/sh", "/monitor.sh"]
