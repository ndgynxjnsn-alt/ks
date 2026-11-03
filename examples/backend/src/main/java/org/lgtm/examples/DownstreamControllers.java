package org.lgtm.examples;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

/** b: is the item in stock? Asks catalog (d). */
@RestController
@Profile("stock")
class StockController {
    private static final Logger log = LoggerFactory.getLogger(StockController.class);
    private final RestClient catalog;

    StockController(RestClient.Builder builder, @Value("${shop.catalog-url}") String catalogUrl) {
        this.catalog = builder.baseUrl(catalogUrl).build();
    }

    @GetMapping("/stock/{id}")
    Map<String, Object> stock(@PathVariable int id) {
        Map<?, ?> item = catalog.get().uri("/items/{id}", id).retrieve().body(Map.class);
        int quantity = ((Number) item.get("stock")).intValue();
        log.info("item {}: {} in stock", id, quantity);
        return Map.of("available", quantity > 0, "quantity", quantity);
    }
}

/** c: the price incl. VAT. Asks catalog (d). */
@RestController
@Profile("pricing")
class PricingController {
    private static final Logger log = LoggerFactory.getLogger(PricingController.class);
    private final RestClient catalog;

    PricingController(RestClient.Builder builder, @Value("${shop.catalog-url}") String catalogUrl) {
        this.catalog = builder.baseUrl(catalogUrl).build();
    }

    @GetMapping("/price/{id}")
    Map<String, Object> price(@PathVariable int id) {
        Map<?, ?> item = catalog.get().uri("/items/{id}", id).retrieve().body(Map.class);
        BigDecimal net = new BigDecimal(item.get("price").toString());
        BigDecimal gross = net.multiply(new BigDecimal("1.19")).setScale(2, RoundingMode.HALF_UP);
        log.info("item {}: {} net, {} gross", id, net, gross);
        return Map.of("net", net, "gross", gross);
    }
}

/** e: confirms the order (here: a log line). */
@RestController
@Profile("notification")
class NotificationController {
    private static final Logger log = LoggerFactory.getLogger(NotificationController.class);

    @PostMapping("/notify")
    void notify(@RequestBody Map<String, Object> order) {
        log.info("order confirmation sent for item {}", order.get("itemId"));
    }
}
