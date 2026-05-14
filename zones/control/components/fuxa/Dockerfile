# UU P&L control-zone HMI. Pinned to FUXA 1.1.7, which carries the
# documented CVE chain visitors come here to find:
#   CVE-2023-32545  path traversal in /api/upload (broken sanitizer)
#   CVE-2023-32546  stored XSS via /api/project content
#   CVE-2023-32547  unauthenticated /api/project read
#
# The image runs FUXA's standard server on :1881. No MySQL sidecar, FUXA
# stores its project JSON locally under _appdata. Operator default is
# "admin" with anonymous read role active until accounts are created.

FROM frangoteam/fuxa:1.1.7

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 1881
ENTRYPOINT ["/entrypoint.sh"]
