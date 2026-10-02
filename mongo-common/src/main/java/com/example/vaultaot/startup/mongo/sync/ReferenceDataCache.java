package com.example.vaultaot.startup.mongo.sync;

import java.util.Map;
import java.util.function.Function;
import java.util.stream.Collectors;

import com.example.vaultaot.startup.mongo.MongoInit;
import com.example.vaultaot.startup.mongo.MongoInit.Mode;
import com.example.vaultaot.startup.mongo.ReferenceItem;

import org.springframework.beans.factory.InitializingBean;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.ApplicationListener;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.data.mongodb.core.index.IndexOperations;
import org.springframework.data.mongodb.core.index.MongoPersistentEntityIndexResolver;

/**
 * The startup work a typical Mongo-backed app does: make sure its indexes exist, then load reference data
 * into memory. BLOCKING does it during bean initialization (so it lands in SPRING_INIT bean_creation and
 * delays readiness); DEFERRED does the same on a virtual thread once the app is ready.
 * (spring.data.mongodb.auto-index-creation=true is the other common way to create indexes at startup; it
 * blocks the same way but can't be timed separately.)
 */
public class ReferenceDataCache implements InitializingBean, ApplicationListener<ApplicationReadyEvent> {

    private final MongoTemplate template;

    private final ReferenceItemRepository repository;

    private final MongoInit init;

    private volatile Map<String, ReferenceItem> byCode = Map.of();

    public ReferenceDataCache(MongoTemplate template, ReferenceItemRepository repository, MongoInit init) {
        if (init.mode() == Mode.REACTIVE) {
            throw new IllegalStateException("mongo.init=reactive needs the reactive app (05-mongo-baseline/reactive)");
        }
        this.template = template;
        this.repository = repository;
        this.init = init;
    }

    @Override
    public void afterPropertiesSet() {
        if (init.mode() == Mode.BLOCKING) {
            long start = System.nanoTime();
            warmUp();
            init.report(millisSince(start), 0, byCode.size());
        }
    }

    @Override
    public void onApplicationEvent(ApplicationReadyEvent event) {
        if (init.mode() == Mode.DEFERRED) {
            Thread.ofVirtual().name("mongo-warm-up").start(() -> {
                long start = System.nanoTime();
                warmUp();
                init.report(0, millisSince(start), byCode.size());
            });
        }
    }

    private void warmUp() {
        IndexOperations indexes = template.indexOps(ReferenceItem.class);
        new MongoPersistentEntityIndexResolver(template.getConverter().getMappingContext())
            .resolveIndexFor(ReferenceItem.class)
            .forEach(indexes::createIndex);
        byCode = repository.findAll().stream().collect(Collectors.toMap(ReferenceItem::code, Function.identity()));
    }

    public boolean isWarm() {
        return !byCode.isEmpty();
    }

    private static long millisSince(long start) {
        return (System.nanoTime() - start) / 1_000_000;
    }
}
