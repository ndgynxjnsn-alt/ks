package org.lgtm.demo;

import java.util.List;
import java.util.concurrent.ThreadLocalRandom;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

/** Places a few orders per second against the shop service so there is always fresh telemetry. */
@Component
@ConditionalOnProperty("demo.load.enabled")
class LoadGenerator {

    private static final Logger log = LoggerFactory.getLogger(LoadGenerator.class);
    private static final List<String> ITEMS = List.of("hammer", "nails", "saw", "anvil", "drill");

    private final RestClient shop;

    LoadGenerator(RestClient.Builder http, @Value("${demo.load.target-url}") String targetUrl) {
        this.shop = http.baseUrl(targetUrl).build();
    }

    @Scheduled(fixedRateString = "${demo.load.interval:500ms}")
    void placeOrder() {
        String item = ITEMS.get(ThreadLocalRandom.current().nextInt(ITEMS.size()));
        try {
            shop.get().uri("/api/orders/{item}", item).retrieve().toBodilessEntity();
        } catch (RestClientException e) {
            log.warn("Order for {} failed: {}", item, e.getMessage());
        }
    }
}
