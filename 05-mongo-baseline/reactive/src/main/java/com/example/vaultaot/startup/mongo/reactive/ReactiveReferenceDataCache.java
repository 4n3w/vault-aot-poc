package com.example.vaultaot.startup.mongo.reactive;

import java.util.Map;

import com.example.vaultaot.startup.mongo.MongoInit;
import com.example.vaultaot.startup.mongo.MongoInit.Mode;
import com.example.vaultaot.startup.mongo.ReferenceItem;
import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;
import reactor.core.publisher.Flux;

import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.ApplicationListener;
import org.springframework.data.mongodb.core.ReactiveMongoTemplate;
import org.springframework.data.mongodb.core.index.MongoPersistentEntityIndexResolver;
import org.springframework.data.mongodb.core.index.ReactiveIndexOperations;

/** The sync apps' ReferenceDataCache as a non-blocking pipeline, subscribed once the app is ready. */
public class ReactiveReferenceDataCache implements ApplicationListener<ApplicationReadyEvent> {

    private static final Log logger = LogFactory.getLog(ReactiveReferenceDataCache.class);

    private final ReactiveMongoTemplate template;

    private final MongoInit init;

    private volatile Map<String, ReferenceItem> byCode = Map.of();

    public ReactiveReferenceDataCache(ReactiveMongoTemplate template, MongoInit init) {
        if (init.mode() != Mode.REACTIVE) {
            throw new IllegalStateException("The reactive app only supports mongo.init=reactive, not " + init.mode());
        }
        this.template = template;
        this.init = init;
    }

    @Override
    public void onApplicationEvent(ApplicationReadyEvent event) {
        long start = System.nanoTime();
        ReactiveIndexOperations indexes = template.indexOps(ReferenceItem.class);
        Flux.fromIterable(new MongoPersistentEntityIndexResolver(template.getConverter().getMappingContext())
                .resolveIndexFor(ReferenceItem.class))
            .concatMap(indexes::createIndex)
            .thenMany(template.findAll(ReferenceItem.class))
            .collectMap(ReferenceItem::code)
            .subscribe(loaded -> {
                byCode = loaded;
                init.report(0, (System.nanoTime() - start) / 1_000_000, loaded.size());
            }, error -> logger.error("Mongo warm-up failed", error));
    }

    public boolean isWarm() {
        return !byCode.isEmpty();
    }
}
