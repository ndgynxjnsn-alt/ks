package org.lgtm.demo;

import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;

import io.micrometer.core.instrument.MeterRegistry;
import io.opentelemetry.api.trace.Span;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;
import org.springframework.web.server.ResponseStatusException;

@RestController
class ShopController {

    private static final Logger log = LoggerFactory.getLogger(ShopController.class);

    private final RestClient inventory;
    private final PriceCalculator prices;
    private final MeterRegistry meters;

    ShopController(RestClient.Builder http, PriceCalculator prices, MeterRegistry meters,
                   @Value("${demo.inventory-url}") String inventoryUrl) {
        this.inventory = http.baseUrl(inventoryUrl).build();
        this.prices = prices;
        this.meters = meters;
    }

    /** Shop role: checks stock in the inventory service, then prices the order (CPU heavy). */
    @GetMapping("/api/orders/{item}")
    Map<String, Object> order(@PathVariable String item) {
        Span.current().setAttribute("shop.item", item);
        log.info("Placing order for {}", item);

        Map<?, ?> stock = inventory.get().uri("/api/inventory/{item}", item).retrieve().body(Map.class);
        long price = prices.calculate(item);

        meters.counter("shop.orders", "item", item).increment();
        log.info("Order for {} placed, price {}", item, price);
        return Map.of("item", item, "price", price, "stock", stock);
    }

    /** Inventory role: variable latency and ~5% failures, so traces show slow and failing spans. */
    @GetMapping("/api/inventory/{item}")
    Map<String, Object> stock(@PathVariable String item) throws InterruptedException {
        var random = ThreadLocalRandom.current();
        Thread.sleep(random.nextInt(5, item.equals("anvil") ? 400 : 60));
        if (random.nextInt(100) < 5) {
            log.error("Inventory database timeout while looking up {}", item);
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, "inventory unavailable");
        }
        int quantity = random.nextInt(0, 100);
        log.info("Stock for {}: {}", item, quantity);
        return Map.of("item", item, "quantity", quantity);
    }
}
