FROM cpclermont/lighthouse-ci-action:2.0.0
RUN npm install -g @shopify/cli@3.69.4 @shopify/theme
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
