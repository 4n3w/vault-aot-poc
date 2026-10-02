package com.example.vaultaot.startup.mongo.sync;

import java.util.Map;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** k3d.sh times the first GET /items after the pod is Ready: it always queries Mongo. */
@RestController
public class ItemsController {

    private final ReferenceItemRepository repository;

    private final ReferenceDataCache cache;

    public ItemsController(ReferenceItemRepository repository, ReferenceDataCache cache) {
        this.repository = repository;
        this.cache = cache;
    }

    @GetMapping("/items")
    Map<String, Object> items() {
        return Map.of("cacheWarm", cache.isWarm(), "category1", repository.countByCategory("category-1"));
    }
}
