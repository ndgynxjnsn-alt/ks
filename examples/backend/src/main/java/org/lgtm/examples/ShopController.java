package org.lgtm.examples;

import io.opentelemetry.api.trace.Span;
import java.util.Map;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

/** a: the entry point. POST /api/orders -> stock (b) and pricing (c), both ask catalog (d); then notification. */
@RestController
@Profile("shop")
class ShopController {
    private static final Logger log = LoggerFactory.getLogger(ShopController.class);
    private final RestClient stock;
    private final RestClient pricing;
    private final RestClient notification;

    ShopController(RestClient.Builder builder, @Value("${shop.stock-url}") String stockUrl,
                   @Value("${shop.pricing-url}") String pricingUrl,
                   @Value("${shop.notification-url}") String notificationUrl) {
        this.stock = builder.clone().baseUrl(stockUrl).build();
        this.pricing = builder.clone().baseUrl(pricingUrl).build();
        this.notification = builder.clone().baseUrl(notificationUrl).build();
    }

    record OrderRequest(int itemId) {}

    @PostMapping("/api/orders")
    Map<String, Object> order(@RequestBody OrderRequest request) {
        if (OrderId.current() == null) {          // a client without an id: the order gets one here
            MDC.put(OrderId.KEY, UUID.randomUUID().toString());
            Span.current().setAttribute(OrderId.KEY, OrderId.current());
        }
        String orderId = OrderId.current();
        log.info("order received for item {}", request.itemId());
        Map<?, ?> availability = stock.get().uri("/stock/{id}", request.itemId()).retrieve().body(Map.class);
        Map<?, ?> price = pricing.get().uri("/price/{id}", request.itemId()).retrieve().body(Map.class);
        notification.post().uri("/notify").body(Map.of("orderId", orderId, "itemId", request.itemId()))
                .retrieve().toBodilessEntity();
        log.info("order placed for item {}", request.itemId());
        return Map.of("orderId", orderId, "itemId", request.itemId(), "stock", availability, "price", price);
    }
}
