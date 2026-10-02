package com.example.vaultaot.startup.mongo.reactive;

import java.util.Map;

import com.example.vaultaot.startup.mongo.ReferenceItem;
import reactor.core.publisher.Mono;

import org.springframework.data.mongodb.core.ReactiveMongoTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import static org.springframework.data.mongodb.core.query.Criteria.where;
import static org.springframework.data.mongodb.core.query.Query.query;

/** k3d.sh times the first GET /items after the pod is Ready: it always queries Mongo. */
@RestController
public class ReactiveItemsController {

    private final ReactiveMongoTemplate template;

    private final ReactiveReferenceDataCache cache;

    public ReactiveItemsController(ReactiveMongoTemplate template, ReactiveReferenceDataCache cache) {
        this.template = template;
        this.cache = cache;
    }

    @GetMapping("/items")
    Mono<Map<String, Object>> items() {
        return template.count(query(where("category").is("category-1")), ReferenceItem.class)
            .map(count -> Map.of("cacheWarm", cache.isWarm(), "category1", count));
    }
}
