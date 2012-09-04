// AFIncrementalStore.m
//
// Copyright (c) 2012 Mattt Thompson (http://mattt.me)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFIncrementalStore.h"
#import "AFHTTPClient.h"

NSString * AFIncrementalStoreUnimplementedMethodException = @"com.alamofire.incremental-store.exceptions.unimplemented-method";

static NSString * const kAFIncrementalStoreResourceIdentifierAttributeName = @"__af_resourceIdentifier";

@interface AFIncrementalStore ()

- (NSManagedObjectContext *)backingManagedObjectContext;

- (NSManagedObjectID *)objectIDForEntity:(NSEntityDescription *)entity
                  withResourceIdentifier:(NSString *)resourceIdentifier;
- (NSManagedObjectID *)objectIDForBackingObjectForEntity:(NSEntityDescription *)entity
                                  withResourceIdentifier:(NSString *)resourceIdentifier;
@end

@implementation AFIncrementalStore {
@private
    NSMutableDictionary *_registeredObjectIDsByResourceIdentifier;
    NSPersistentStoreCoordinator *_backingPersistentStoreCoordinator;
    NSManagedObjectContext *_backingManagedObjectContext;
}
@synthesize HTTPClient = _HTTPClient;
@synthesize backingPersistentStoreCoordinator = _backingPersistentStoreCoordinator;

+ (NSString *)type {
    @throw([NSException exceptionWithName:AFIncrementalStoreUnimplementedMethodException reason:NSLocalizedString(@"Unimplemented method: +type. Must be overridden in a subclass", nil) userInfo:nil]);
}

- (BOOL)loadMetadata:(NSError *__autoreleasing *)error {
    if(nil == _backingPersistentStoreCoordinator) {
        NSMutableDictionary *mutableMetadata = [NSMutableDictionary dictionary];
        [mutableMetadata setValue:[[NSProcessInfo processInfo] globallyUniqueString] forKey:NSStoreUUIDKey];
        [mutableMetadata setValue:[self type] forKey:NSStoreTypeKey];
        [self setMetadata:mutableMetadata];
        
        _registeredObjectIDsByResourceIdentifier = [[NSMutableDictionary alloc] init];
        
        NSManagedObjectModel *model = [self.persistentStoreCoordinator.managedObjectModel copy];
        for (NSEntityDescription *entity in model.entities) {
            // Don't add resource identifier property for sub-entities, as they already exist in the super-entity 
            if ([entity superentity]) {
                continue;
            }
            
            NSAttributeDescription *resourceIdentifierProperty = [[NSAttributeDescription alloc] init];
            [resourceIdentifierProperty setName:kAFIncrementalStoreResourceIdentifierAttributeName];
            [resourceIdentifierProperty setAttributeType:NSStringAttributeType];
            [resourceIdentifierProperty setIndexed:YES];
            [entity setProperties:[entity.properties arrayByAddingObject:resourceIdentifierProperty]];
        }
        
        _backingPersistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
        
        return YES;
    } else {
        return NO;
    }
}

- (NSManagedObjectContext *)backingManagedObjectContext {
    if (!_backingManagedObjectContext) {
        _backingManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        _backingManagedObjectContext.persistentStoreCoordinator = _backingPersistentStoreCoordinator;
        _backingManagedObjectContext.retainsRegisteredObjects = YES;
    }
    
    return _backingManagedObjectContext;
}

- (NSManagedObjectID *)objectIDForEntity:(NSEntityDescription *)entity
                  withResourceIdentifier:(NSString *)resourceIdentifier {
    NSManagedObjectID *objectID = [_registeredObjectIDsByResourceIdentifier objectForKey:resourceIdentifier];
    if (objectID == nil) {
        objectID = [self newObjectIDForEntity:entity referenceObject:resourceIdentifier];
    }
    
    return objectID;
}

- (NSManagedObjectID *)objectIDForBackingObjectForEntity:(NSEntityDescription *)entity
                                  withResourceIdentifier:(NSString *)resourceIdentifier
{
    if (!resourceIdentifier) {
        return nil;
    }
    
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:[entity name]];
    fetchRequest.resultType = NSManagedObjectIDResultType;
    fetchRequest.fetchLimit = 1;
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"%K = %@", kAFIncrementalStoreResourceIdentifierAttributeName, resourceIdentifier];
    
    NSError *error = nil;
    NSArray *results = [[self backingManagedObjectContext] executeFetchRequest:fetchRequest error:&error];
    if (error) {
        NSLog(@"Error: %@", error);
        return nil;
    }
    
    return [results lastObject];
}

- (NSManagedObjectContext*) automergingChildContextFromParentContext:(NSManagedObjectContext*) context {
  NSManagedObjectContext* childContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
  childContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
  childContext.persistentStoreCoordinator = context.persistentStoreCoordinator;
  __weak NSManagedObjectContext* parentContext = context;
  [[NSNotificationCenter defaultCenter] addObserverForName:NSManagedObjectContextDidSaveNotification
                                                    object:childContext
                                                     queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(NSNotification *note) {
                                                  NSManagedObjectContext* ctx = parentContext;
                                                  [ctx mergeChangesFromContextDidSaveNotification:note];
                                                }];
  return childContext;
}

- (id)executeRequest:(NSPersistentStoreRequest *)persistentStoreRequest
         withContext:(NSManagedObjectContext *)context
               error:(NSError *__autoreleasing *)error
{
    if (persistentStoreRequest.requestType == NSFetchRequestType) {
        NSFetchRequest *fetchRequest = (NSFetchRequest *)persistentStoreRequest;
        
        NSURLRequest *request = [self.HTTPClient requestForFetchRequest:fetchRequest withContext:context];
        if ([request URL]) {
            AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
                id representationOrArrayOfRepresentations = [self.HTTPClient representationOrArrayOfRepresentationsFromResponseObject:responseObject];
                
                NSArray *representations = nil;
                if ([representationOrArrayOfRepresentations isKindOfClass:[NSArray class]]) {
                    representations = representationOrArrayOfRepresentations;
                } else {
                    representations = [NSArray arrayWithObject:representationOrArrayOfRepresentations];
                }
                
                NSManagedObjectContext *childContext = [self automergingChildContextFromParentContext:context];

                NSManagedObjectContext *backingContext = [self backingManagedObjectContext];
                [childContext performBlock:^{
                    NSEntityDescription *entity = fetchRequest.entity;
                    for (NSDictionary *representation in representations) {
                        NSString *resourceIdentifier = [self.HTTPClient resourceIdentifierForRepresentation:representation ofEntity:entity fromResponse:operation.response];
                        NSDictionary *attributes = [self.HTTPClient attributesForRepresentation:representation ofEntity:entity fromResponse:operation.response];
                        NSDictionary *relationshipRepresentations = [self.HTTPClient representationsForRelationshipsFromRepresentation:representation ofEntity:entity fromResponse:operation.response];
                        
                        NSManagedObjectID *backingObjectID = [self objectIDForBackingObjectForEntity:entity
                                                                              withResourceIdentifier:resourceIdentifier];
                        
                        NSManagedObject *backingObject = nil;
                        if(nil == backingObjectID) {
                          backingObject  = [NSEntityDescription insertNewObjectForEntityForName:entity.name
                                                                       inManagedObjectContext:backingContext];
                        } else {
                          backingObject = [backingContext existingObjectWithID:backingObjectID
                                                                       error:nil];
                        }
                        [backingObject setValue:resourceIdentifier
                                         forKey:kAFIncrementalStoreResourceIdentifierAttributeName];
                        [backingObject setValuesForKeysWithDictionary:attributes];
                                                  
                        //either get the existing or create a new one
                        NSManagedObjectID* childObjectID = [self objectIDForEntity:entity
                                                          withResourceIdentifier:resourceIdentifier];
                        //either get existing or create a new one
                        NSManagedObject *childObject = [childContext objectWithID:childObjectID];
                        //if the backingObjectID is nil, there should also be no object in the client's context
                        //so insert it
                        if (backingObjectID == nil) {
                            [childContext insertObject:childObject];
                        }
                        [childObject setValuesForKeysWithDictionary:attributes];
                        
                        for (NSString *relationshipName in relationshipRepresentations) {
                            id relationshipRepresentationOrArrayOfRepresentations = [relationshipRepresentations objectForKey:relationshipName];
                            NSRelationshipDescription *relationship = [[entity relationshipsByName] valueForKey:relationshipName];
                            
                            if (relationship) {
                                if ([relationship isToMany]) {
                                    id mutableManagedRelationshipObjects = [relationship isOrdered] ? [NSMutableOrderedSet orderedSet] : [NSMutableSet set];
                                    id mutableBackingRelationshipObjects = [relationship isOrdered] ? [NSMutableOrderedSet orderedSet] : [NSMutableSet set];
                                    
                                    for (NSDictionary *relationshipRepresentation in relationshipRepresentationOrArrayOfRepresentations) {
                                        NSString *relationshipResourceIdentifier = [self.HTTPClient resourceIdentifierForRepresentation:relationshipRepresentationOrArrayOfRepresentations ofEntity:relationship.entity fromResponse:operation.response];
                                        NSDictionary *relationshipAttributes = [self.HTTPClient attributesForRepresentation:relationshipRepresentationOrArrayOfRepresentations ofEntity:relationship.destinationEntity fromResponse:operation.response];
                                        
                                        NSManagedObjectID *relationshipObjectID = [self objectIDForBackingObjectForEntity:relationship.destinationEntity withResourceIdentifier:relationshipResourceIdentifier];
                                        
                                        NSManagedObject *backingRelationshipObject = (relationshipObjectID != nil) ? [backingContext objectWithID:relationshipObjectID] : [NSEntityDescription insertNewObjectForEntityForName:relationship.destinationEntity.name inManagedObjectContext:backingContext];
                                        [backingRelationshipObject setValue:relationshipResourceIdentifier forKey:kAFIncrementalStoreResourceIdentifierAttributeName];
                                        [backingRelationshipObject setValuesForKeysWithDictionary:relationshipAttributes];
                                        [mutableBackingRelationshipObjects addObject:backingRelationshipObject];
                                        
                                        NSManagedObject *managedRelationshipObject = [childContext existingObjectWithID:[self objectIDForEntity:relationship.destinationEntity withResourceIdentifier:relationshipResourceIdentifier] error:nil];
                                        [managedRelationshipObject setValuesForKeysWithDictionary:relationshipAttributes];
                                        [mutableManagedRelationshipObjects addObject:managedRelationshipObject];
                                        if (relationshipObjectID == nil) {
                                            [childContext insertObject:managedRelationshipObject];
                                        }
                                    }
                                    
                                    [backingObject setValue:mutableBackingRelationshipObjects forKey:relationship.name];
                                    [childObject setValue:mutableManagedRelationshipObjects forKey:relationship.name];
                                } else {
                                    NSString *relationshipResourceIdentifier = [self.HTTPClient resourceIdentifierForRepresentation:relationshipRepresentationOrArrayOfRepresentations ofEntity:relationship.destinationEntity fromResponse:operation.response];
                                    NSDictionary *relationshipAttributes = [self.HTTPClient attributesForRepresentation:relationshipRepresentationOrArrayOfRepresentations ofEntity:relationship.destinationEntity fromResponse:operation.response];

                                    NSManagedObjectID *relationshipObjectID = [self objectIDForBackingObjectForEntity:relationship.destinationEntity withResourceIdentifier:relationshipResourceIdentifier];

                                    NSManagedObject *backingRelationshipObject = (relationshipObjectID != nil) ? [backingContext objectWithID:relationshipObjectID] : [NSEntityDescription insertNewObjectForEntityForName:relationship.destinationEntity.name inManagedObjectContext:backingContext];
                                    [backingRelationshipObject setValue:relationshipResourceIdentifier forKey:kAFIncrementalStoreResourceIdentifierAttributeName];
                                    [backingRelationshipObject setValuesForKeysWithDictionary:relationshipAttributes];
                                    [backingObject setValue:backingRelationshipObject forKey:relationship.name];
                                    
                                    NSManagedObject *managedRelationshipObject = [childContext existingObjectWithID:[self objectIDForEntity:relationship.destinationEntity withResourceIdentifier:relationshipResourceIdentifier] error:nil];
                                    [managedRelationshipObject setValuesForKeysWithDictionary:relationshipAttributes];
                                    [childObject setValue:managedRelationshipObject forKey:relationship.name];
                                    if (relationshipObjectID == nil) {
                                        [childContext insertObject:managedRelationshipObject];
                                    }
                                }
                            }
                        }
                    }
                    
                    if (![backingContext save:error] || ![childContext save:error]) {
                        NSLog(@"Error: %@", *error);
                    }
                }];
            } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                NSLog(@"Error: %@", error);
            }];
            
            operation.successCallbackQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
            [self.HTTPClient enqueueHTTPRequestOperation:operation];
        }
        
        NSManagedObjectContext *backingContext = [self backingManagedObjectContext];
        NSArray *results = nil;
        
        NSFetchRequestResultType resultType = fetchRequest.resultType;
        switch (resultType) {
            case NSManagedObjectResultType: {
                fetchRequest = [fetchRequest copy];
                fetchRequest.entity = [NSEntityDescription entityForName:fetchRequest.entityName inManagedObjectContext:backingContext];
                fetchRequest.resultType = NSDictionaryResultType;
                fetchRequest.propertiesToFetch = @[ kAFIncrementalStoreResourceIdentifierAttributeName ];
                results = [backingContext executeFetchRequest:fetchRequest error:error];
                NSMutableArray *mutableObjects = [NSMutableArray arrayWithCapacity:[results count]];
                for (NSString *resourceIdentifier in [results valueForKeyPath:kAFIncrementalStoreResourceIdentifierAttributeName]) {
                    NSManagedObjectID *objectID = [self objectIDForEntity:fetchRequest.entity
                                                   withResourceIdentifier:resourceIdentifier];
                    NSManagedObject *object = [context objectWithID:objectID];
                    [mutableObjects addObject:object];
                }
                                
                return mutableObjects;
            }
            case NSManagedObjectIDResultType:
            case NSDictionaryResultType:
            case NSCountResultType:
                return [backingContext executeFetchRequest:fetchRequest error:error];
            default:
                goto _error;
        }
    } else {
        switch (persistentStoreRequest.requestType) {
            case NSSaveRequestType:
                return @[];
            default:
                goto _error;
        }
    }
    
    return nil;
    
    _error: {
        if (error) {
          NSMutableDictionary *mutableUserInfo = [NSMutableDictionary dictionary];
          NSString* errorDescription = [NSString stringWithFormat:
                                        NSLocalizedString(@"Unsupported NSFetchRequestResultType, %d", nil),
                                        persistentStoreRequest.requestType];
          [mutableUserInfo setValue:errorDescription
                             forKey:NSLocalizedDescriptionKey];

            *error = [[NSError alloc] initWithDomain:AFNetworkingErrorDomain
                                                code:0
                                            userInfo:mutableUserInfo];
        }
    
        return nil;
    }
}

#pragma mark -

- (NSIncrementalStoreNode *)newValuesForObjectWithID:(NSManagedObjectID *)objectID
                                         withContext:(NSManagedObjectContext *)context
                                               error:(NSError *__autoreleasing *)error
{
    //build the fetch request to query the values from the backing store
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:[[objectID entity] name]];
    fetchRequest.resultType = NSDictionaryResultType;
    fetchRequest.fetchLimit = 1;
    fetchRequest.includesSubentities = NO;
    fetchRequest.propertiesToFetch = [[[NSEntityDescription entityForName:fetchRequest.entityName
                                                   inManagedObjectContext:context]
                                       attributesByName] allKeys];
    id referenceObject = [self referenceObjectForObjectID:objectID];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"%K = %@",
                              kAFIncrementalStoreResourceIdentifierAttributeName, referenceObject];
    
    //fetch from the backing store
    NSArray *results = [[self backingManagedObjectContext] executeFetchRequest:fetchRequest error:error];
    if(nil == results) {
      NSLog(@"Error: Failed to fetch values from backingContext for object with id: '%@'. Error: %@", objectID, (error) ? *error : nil);
    }
  
    //return nil of we can't find the an object with the given ID
    if(0 == [results count]) {
      return nil;
    }

    //build NSIncrementalStoreNode that we need to return from the fetched data
    NSDictionary *attributeValues = [results lastObject];
    NSIncrementalStoreNode *node = [[NSIncrementalStoreNode alloc] initWithObjectID:objectID
                                                                         withValues:attributeValues
                                                                            version:1];
    //optionally ask the delegate if we should queue an update of the values
    //which will be stored to the backingContext
    if ([self.HTTPClient respondsToSelector:@selector(shouldFetchRemoteAttributeValuesForObjectWithID:inManagedObjectContext:)] &&
        [self.HTTPClient shouldFetchRemoteAttributeValuesForObjectWithID:objectID inManagedObjectContext:context]) {
        if (attributeValues) {
            NSManagedObjectContext *backingManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
            backingManagedObjectContext.parentContext = context;
            backingManagedObjectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
            
            NSURLRequest *request = [self.HTTPClient requestWithMethod:@"GET" pathForObjectWithID:objectID withContext:context];
            
            if ([request URL]) {
                AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, NSDictionary *representation) {
                    NSManagedObject *managedObject = [backingManagedObjectContext existingObjectWithID:objectID error:error];
                    
                    NSMutableDictionary *mutablePropertyValues = [attributeValues mutableCopy];
                    [mutablePropertyValues addEntriesFromDictionary:[self.HTTPClient attributesForRepresentation:representation ofEntity:managedObject.entity fromResponse:operation.response]];
                    [managedObject setValuesForKeysWithDictionary:mutablePropertyValues];
                    
                    if (![backingManagedObjectContext save:error]) {
                        NSLog(@"Error: %@", *error);
                    }
                } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                    NSLog(@"Error: %@, %@", operation, error);
                }];
                
                [self.HTTPClient enqueueHTTPRequestOperation:operation];
            }
        }
    }
    
    return node;
}

- (id)newValueForRelationship:(NSRelationshipDescription *)relationship
              forObjectWithID:(NSManagedObjectID *)objectID
                  withContext:(NSManagedObjectContext *)context
                        error:(NSError *__autoreleasing *)error
{
    if ([self.HTTPClient respondsToSelector:@selector(shouldFetchRemoteValuesForRelationship:forObjectWithID:inManagedObjectContext:)]
        && [self.HTTPClient shouldFetchRemoteValuesForRelationship:relationship forObjectWithID:objectID inManagedObjectContext:context]) {
        
        NSURLRequest *request = [self.HTTPClient requestWithMethod:@"GET"
                                               pathForRelationship:relationship
                                                   forObjectWithID:objectID
                                                       withContext:context];
        
        if ([request URL] && ![[context existingObjectWithID:objectID error:nil] hasChanges]) {
            
            NSManagedObjectContext *backingContext = [self backingManagedObjectContext];
            NSManagedObjectContext *childContext = [self automergingChildContextFromParentContext:context];
            
            AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
                id representationOrArrayOfRepresentations = [self.HTTPClient representationOrArrayOfRepresentationsFromResponseObject:responseObject];
                
                NSArray *representations = nil;
                if ([representationOrArrayOfRepresentations isKindOfClass:[NSArray class]]) {
                    representations = representationOrArrayOfRepresentations;
                } else {
                    representations = [NSArray arrayWithObject:representationOrArrayOfRepresentations];
                }
                
                [childContext performBlock:^{
                    NSManagedObject *managedObject = [childContext existingObjectWithID:[self objectIDForEntity:[objectID entity] withResourceIdentifier:[self referenceObjectForObjectID:objectID]] error:nil];
                    NSManagedObject *backingObject = [backingContext existingObjectWithID:[self objectIDForBackingObjectForEntity:[objectID entity] withResourceIdentifier:[self referenceObjectForObjectID:objectID]] error:nil];

                    id mutableBackingRelationshipObjects = [relationship isOrdered] ? [NSMutableOrderedSet orderedSetWithCapacity:[representations count]] : [NSMutableSet setWithCapacity:[representations count]];
                    id mutableManagedRelationshipObjects = [relationship isOrdered] ? [NSMutableOrderedSet orderedSetWithCapacity:[representations count]] : [NSMutableSet setWithCapacity:[representations count]];

                    NSEntityDescription *entity = relationship.destinationEntity;
                    
                    for (NSDictionary *representation in representations) {
                        NSString *relationshipResourceIdentifier = [self.HTTPClient resourceIdentifierForRepresentation:representation
                                                                                                               ofEntity:entity
                                                                                                           fromResponse:operation.response];
                        NSManagedObjectID *relationshipObjectID = [self objectIDForBackingObjectForEntity:relationship.destinationEntity
                                                                                   withResourceIdentifier:relationshipResourceIdentifier];
                        NSDictionary *relationshipAttributes = [self.HTTPClient attributesForRepresentation:representation
                                                                                                   ofEntity:entity
                                              
                                                                                               fromResponse:operation.response];
                        NSManagedObject *backingRelationshipObject = (relationshipObjectID != nil) ?
                          [backingContext existingObjectWithID:relationshipObjectID error:nil] :
                          [NSEntityDescription insertNewObjectForEntityForName:[relationship.destinationEntity name] inManagedObjectContext:backingContext];
                        [backingRelationshipObject setValuesForKeysWithDictionary:relationshipAttributes];
                        [mutableBackingRelationshipObjects addObject:backingRelationshipObject];

                        NSManagedObject *managedRelationshipObject = [childContext objectWithID:[self objectIDForEntity:relationship.destinationEntity
                                                                                                 withResourceIdentifier:relationshipResourceIdentifier]];
                        [managedRelationshipObject setValuesForKeysWithDictionary:relationshipAttributes];
                        [mutableManagedRelationshipObjects addObject:managedRelationshipObject];
                        if (relationshipObjectID == nil) {
                            [childContext insertObject:managedRelationshipObject];
                        }
                    }
                    
                    if ([relationship isToMany]) {
                        [managedObject setValue:mutableManagedRelationshipObjects forKey:relationship.name];
                        [backingObject setValue:mutableBackingRelationshipObjects forKey:relationship.name];
                    } else {
                        [managedObject setValue:[mutableManagedRelationshipObjects anyObject] forKey:relationship.name];
                        [backingObject setValue:[mutableBackingRelationshipObjects anyObject] forKey:relationship.name];
                    }
                
                    if (![backingContext save:error] || ![childContext save:error]) {
                        NSLog(@"Error: %@", *error);
                    }
                }];
            } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                NSLog(@"Error: %@, %@", operation, error);
            }];
            
            operation.successCallbackQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
            [self.HTTPClient enqueueHTTPRequestOperation:operation];
        }
    }
    
    NSManagedObjectID *backingObjectID = [self objectIDForBackingObjectForEntity:[objectID entity]
                                                          withResourceIdentifier:[self referenceObjectForObjectID:objectID]];
    NSManagedObject *backingObject = (backingObjectID == nil) ? nil : [[self backingManagedObjectContext] existingObjectWithID:backingObjectID error:nil];
    
    if (backingObject && ![backingObject hasChanges]) {
        id backingRelationshipObject = [backingObject valueForKeyPath:relationship.name];
        if ([relationship isToMany]) {
            NSMutableArray *mutableObjects = [NSMutableArray arrayWithCapacity:[backingRelationshipObject count]];
            for (NSString *resourceIdentifier in [backingRelationshipObject valueForKeyPath:kAFIncrementalStoreResourceIdentifierAttributeName]) {
                NSManagedObjectID *objectID = [self objectIDForEntity:relationship.destinationEntity withResourceIdentifier:resourceIdentifier];
                [mutableObjects addObject:objectID];
            }
                        
            return mutableObjects;            
        } else {
            NSString *resourceIdentifier = [backingRelationshipObject valueForKeyPath:kAFIncrementalStoreResourceIdentifierAttributeName];
            NSManagedObjectID *objectID = [self objectIDForEntity:relationship.destinationEntity withResourceIdentifier:resourceIdentifier];
            return objectID ?: [NSNull null];
        }
    } else {
        if ([relationship isToMany]) {
            return [NSArray array];
        } else {
            return [NSNull null];
        }
    }
}

#pragma mark - NSIncrementalStore

- (void)managedObjectContextDidRegisterObjectsWithIDs:(NSArray *)objectIDs {
    [super managedObjectContextDidRegisterObjectsWithIDs:objectIDs];
    for (NSManagedObjectID *objectID in objectIDs) {
        [_registeredObjectIDsByResourceIdentifier setObject:objectID forKey:[self referenceObjectForObjectID:objectID]];
    }
}

- (void)managedObjectContextDidUnregisterObjectsWithIDs:(NSArray *)objectIDs {
    [super managedObjectContextDidUnregisterObjectsWithIDs:objectIDs];
    for (NSManagedObjectID *objectID in objectIDs) {
        [_registeredObjectIDsByResourceIdentifier removeObjectForKey:[self referenceObjectForObjectID:objectID]];
    }    
}

- (NSArray*)obtainPermanentIDsForObjects:(NSArray*)array error:(NSError **)error {
  NSMutableArray* mutableArray = [NSMutableArray arrayWithCapacity:array.count];
  for(NSManagedObject* object in array) {
    [mutableArray addObject:object.objectID];
  }
  return mutableArray;
}

@end
