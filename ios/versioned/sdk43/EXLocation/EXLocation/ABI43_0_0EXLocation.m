// Copyright 2016-present 650 Industries. All rights reserved.

#import <ABI43_0_0EXLocation/ABI43_0_0EXLocation.h>
#import <ABI43_0_0EXLocation/ABI43_0_0EXLocationDelegate.h>
#import <ABI43_0_0EXLocation/ABI43_0_0EXLocationTaskConsumer.h>
#import <ABI43_0_0EXLocation/ABI43_0_0EXGeofencingTaskConsumer.h>
#import <ABI43_0_0EXLocation/ABI43_0_0EXLocationPermissionRequester.h>
#import <ABI43_0_0EXLocation/ABI43_0_0EXForegroundPermissionRequester.h>
#import <ABI43_0_0EXLocation/ABI43_0_0EXBackgroundLocationPermissionRequester.h>

#import <CoreLocation/CLLocationManager.h>
#import <CoreLocation/CLLocationManagerDelegate.h>
#import <CoreLocation/CLHeading.h>
#import <CoreLocation/CLGeocoder.h>
#import <CoreLocation/CLPlacemark.h>
#import <CoreLocation/CLError.h>
#import <CoreLocation/CLCircularRegion.h>

#import <ABI43_0_0ExpoModulesCore/ABI43_0_0EXEventEmitterService.h>

#import <ABI43_0_0ExpoModulesCore/ABI43_0_0EXPermissionsInterface.h>
#import <ABI43_0_0ExpoModulesCore/ABI43_0_0EXPermissionsMethodsDelegate.h>

#import <ABI43_0_0UMTaskManagerInterface/ABI43_0_0UMTaskManagerInterface.h>

NS_ASSUME_NONNULL_BEGIN

NSString * const ABI43_0_0EXLocationChangedEventName = @"Expo.locationChanged";
NSString * const ABI43_0_0EXHeadingChangedEventName = @"Expo.headingChanged";

@interface ABI43_0_0EXLocation ()

@property (nonatomic, strong) NSMutableDictionary<NSNumber *, ABI43_0_0EXLocationDelegate*> *delegates;
@property (nonatomic, strong) NSMutableSet<ABI43_0_0EXLocationDelegate *> *retainedDelegates;
@property (nonatomic, weak) id<ABI43_0_0EXEventEmitterService> eventEmitter;
@property (nonatomic, weak) id<ABI43_0_0EXPermissionsInterface> permissionsManager;
@property (nonatomic, weak) id<ABI43_0_0UMTaskManagerInterface> tasksManager;

@end

@implementation ABI43_0_0EXLocation

ABI43_0_0EX_EXPORT_MODULE(ExpoLocation);

- (instancetype)init
{
  if (self = [super init]) {
    _delegates = [NSMutableDictionary dictionary];
    _retainedDelegates = [NSMutableSet set];
  }
  return self;
}

- (void)setModuleRegistry:(ABI43_0_0EXModuleRegistry *)moduleRegistry
{
  _eventEmitter = [moduleRegistry getModuleImplementingProtocol:@protocol(ABI43_0_0EXEventEmitterService)];
  _tasksManager = [moduleRegistry getModuleImplementingProtocol:@protocol(ABI43_0_0UMTaskManagerInterface)];

  _permissionsManager = [moduleRegistry getModuleImplementingProtocol:@protocol(ABI43_0_0EXPermissionsInterface)];
  [ABI43_0_0EXPermissionsMethodsDelegate registerRequesters:@[
    [ABI43_0_0EXLocationPermissionRequester new],
    [ABI43_0_0EXForegroundPermissionRequester new],
    [ABI43_0_0EXBackgroundLocationPermissionRequester new]
  ] withPermissionsManager:_permissionsManager];
}

- (dispatch_queue_t)methodQueue
{
  // Location managers must be created on the main thread
  return dispatch_get_main_queue();
}

# pragma mark - ABI43_0_0EXEventEmitter

- (NSArray<NSString *> *)supportedEvents
{
  return @[ABI43_0_0EXLocationChangedEventName, ABI43_0_0EXHeadingChangedEventName];
}

- (void)startObserving {}
- (void)stopObserving {}

# pragma mark - Exported methods

ABI43_0_0EX_EXPORT_METHOD_AS(getProviderStatusAsync,
                    resolver:(ABI43_0_0EXPromiseResolveBlock)resolve
                    rejecter:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  resolve(@{
            @"locationServicesEnabled": @([CLLocationManager locationServicesEnabled]),
            @"backgroundModeEnabled": @([_tasksManager hasBackgroundModeEnabled:@"location"]),
            });
}


ABI43_0_0EX_EXPORT_METHOD_AS(getCurrentPositionAsync,
                    options:(NSDictionary *)options
                    resolver:(ABI43_0_0EXPromiseResolveBlock)resolve
                    rejecter:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  if (![self checkForegroundPermissions:reject]) {
    return;
  }

  CLLocationManager *locMgr = [self locationManagerWithOptions:options];

  __weak typeof(self) weakSelf = self;
  __block ABI43_0_0EXLocationDelegate *delegate;

  delegate = [[ABI43_0_0EXLocationDelegate alloc] initWithId:nil withLocMgr:locMgr onUpdateLocations:^(NSArray<CLLocation *> * _Nonnull locations) {
    if (delegate != nil) {
      if (locations.lastObject != nil) {
        resolve([ABI43_0_0EXLocation exportLocation:locations.lastObject]);
      } else {
        reject(@"E_LOCATION_NOT_FOUND", @"Current location not found.", nil);
      }
      [weakSelf.retainedDelegates removeObject:delegate];
      delegate = nil;
    }
  } onUpdateHeadings:nil onError:^(NSError *error) {
    reject(@"E_LOCATION_UNAVAILABLE", [@"Cannot obtain current location: " stringByAppendingString:error.description], nil);
  }];

  // retain location manager delegate so it will not dealloc until onUpdateLocations gets called
  [_retainedDelegates addObject:delegate];

  locMgr.delegate = delegate;
  [locMgr requestLocation];
}

ABI43_0_0EX_EXPORT_METHOD_AS(watchPositionImplAsync,
                    watchId:(nonnull NSNumber *)watchId
                    options:(NSDictionary *)options
                    resolver:(ABI43_0_0EXPromiseResolveBlock)resolve
                    rejecter:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  if (![self checkForegroundPermissions:reject]) {
    return;
  }

  __weak typeof(self) weakSelf = self;
  CLLocationManager *locMgr = [self locationManagerWithOptions:options];

  ABI43_0_0EXLocationDelegate *delegate = [[ABI43_0_0EXLocationDelegate alloc] initWithId:watchId withLocMgr:locMgr onUpdateLocations:^(NSArray<CLLocation *> *locations) {
    if (locations.lastObject != nil && weakSelf != nil) {
      __strong typeof(weakSelf) strongSelf = weakSelf;

      CLLocation *loc = locations.lastObject;
      NSDictionary *body = @{
                             @"watchId": watchId,
                             @"location": [ABI43_0_0EXLocation exportLocation:loc],
                             };

      [strongSelf->_eventEmitter sendEventWithName:ABI43_0_0EXLocationChangedEventName body:body];
    }
  } onUpdateHeadings:nil onError:^(NSError *error) {
    // TODO: report errors
    // (ben) error could be (among other things):
    //   - kCLErrorDenied - we should use the same UNAUTHORIZED behavior as elsewhere
    //   - kCLErrorLocationUnknown - we can actually ignore this error and keep tracking
    //     location (I think -- my knowledge might be a few months out of date)
  }];

  _delegates[delegate.watchId] = delegate;
  locMgr.delegate = delegate;
  [locMgr startUpdatingLocation];
  resolve([NSNull null]);
}

ABI43_0_0EX_EXPORT_METHOD_AS(getLastKnownPositionAsync,
                    getLastKnownPositionWithOptions:(NSDictionary *)options
                    resolve:(ABI43_0_0EXPromiseResolveBlock)resolve
                    rejecter:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  if (![self checkForegroundPermissions:reject]) {
    return;
  }
  CLLocation *location = [[self locationManagerWithOptions:nil] location];

  if ([self.class isLocation:location validWithOptions:options]) {
    resolve([ABI43_0_0EXLocation exportLocation:location]);
  } else {
    resolve([NSNull null]);
  }
}

// Watch method for getting compass updates
ABI43_0_0EX_EXPORT_METHOD_AS(watchDeviceHeading,
                    watchHeadingWithWatchId:(nonnull NSNumber *)watchId
                    resolve:(ABI43_0_0EXPromiseResolveBlock)resolve
                    reject:(ABI43_0_0EXPromiseRejectBlock)reject) {
  if (![self checkForegroundPermissions:reject]) {
    return;
  }

  __weak typeof(self) weakSelf = self;
  CLLocationManager *locMgr = [[CLLocationManager alloc] init];

  locMgr.distanceFilter = kCLDistanceFilterNone;
  locMgr.desiredAccuracy = kCLLocationAccuracyBest;
  locMgr.allowsBackgroundLocationUpdates = NO;

  ABI43_0_0EXLocationDelegate *delegate = [[ABI43_0_0EXLocationDelegate alloc] initWithId:watchId withLocMgr:locMgr onUpdateLocations: nil onUpdateHeadings:^(CLHeading *newHeading) {
    if (newHeading != nil && weakSelf != nil) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      NSNumber *accuracy;

      // Convert iOS heading accuracy to Android system
      // 3: high accuracy, 2: medium, 1: low, 0: none
      if (newHeading.headingAccuracy > 50 || newHeading.headingAccuracy < 0) {
        accuracy = @(0);
      } else if (newHeading.headingAccuracy > 35) {
        accuracy = @(1);
      } else if (newHeading.headingAccuracy > 20) {
        accuracy = @(2);
      } else {
        accuracy = @(3);
      }
      NSDictionary *body = @{@"watchId": watchId,
                             @"heading": @{
                                 @"trueHeading": @(newHeading.trueHeading),
                                 @"magHeading": @(newHeading.magneticHeading),
                                 @"accuracy": accuracy,
                                 },
                             };
      [strongSelf->_eventEmitter sendEventWithName:ABI43_0_0EXHeadingChangedEventName body:body];
    }
  } onError:^(NSError *error) {
    // Error getting updates
  }];

  _delegates[delegate.watchId] = delegate;
  locMgr.delegate = delegate;
  [locMgr startUpdatingHeading];
  resolve([NSNull null]);
}

ABI43_0_0EX_EXPORT_METHOD_AS(removeWatchAsync,
                    watchId:(nonnull NSNumber *)watchId
                    resolver:(ABI43_0_0EXPromiseResolveBlock)resolve
                    rejecter:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  ABI43_0_0EXLocationDelegate *delegate = _delegates[watchId];

  if (delegate) {
    // Unsuscribe from both location and heading updates
    [delegate.locMgr stopUpdatingLocation];
    [delegate.locMgr stopUpdatingHeading];
    delegate.locMgr.delegate = nil;
    [_delegates removeObjectForKey:watchId];
  }
  resolve([NSNull null]);
}

ABI43_0_0EX_EXPORT_METHOD_AS(geocodeAsync,
                    address:(nonnull NSString *)address
                    resolver:(ABI43_0_0EXPromiseResolveBlock)resolve
                    rejecter:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  CLGeocoder *geocoder = [[CLGeocoder alloc] init];

  [geocoder geocodeAddressString:address completionHandler:^(NSArray* placemarks, NSError* error){
    if (!error) {
      NSMutableArray *results = [NSMutableArray arrayWithCapacity:placemarks.count];
      for (CLPlacemark* placemark in placemarks) {
        CLLocation *location = placemark.location;
        [results addObject:@{
                             @"latitude": @(location.coordinate.latitude),
                             @"longitude": @(location.coordinate.longitude),
                             @"altitude": @(location.altitude),
                             @"accuracy": @(location.horizontalAccuracy),
                             }];
      }
      resolve(results);
    } else if (error.code == kCLErrorGeocodeFoundNoResult || error.code == kCLErrorGeocodeFoundPartialResult) {
      resolve(@[]);
    } else if (error.code == kCLErrorNetwork) {
      reject(@"E_RATE_EXCEEDED", @"Rate limit exceeded - too many requests", error);
    } else {
      reject(@"E_GEOCODING_FAILED", @"Error while geocoding an address", error);
    }
  }];
}

ABI43_0_0EX_EXPORT_METHOD_AS(reverseGeocodeAsync,
                    locationMap:(nonnull NSDictionary *)locationMap
                    resolver:(ABI43_0_0EXPromiseResolveBlock)resolve
                    rejecter:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  CLGeocoder *geocoder = [[CLGeocoder alloc] init];
  CLLocation *location = [[CLLocation alloc] initWithLatitude:[locationMap[@"latitude"] floatValue] longitude:[locationMap[@"longitude"] floatValue]];

  [geocoder reverseGeocodeLocation:location completionHandler:^(NSArray* placemarks, NSError* error){
    if (!error) {
      NSMutableArray *results = [NSMutableArray arrayWithCapacity:placemarks.count];
      for (CLPlacemark* placemark in placemarks) {
        NSDictionary *address = @{
                                  @"city": ABI43_0_0EXNullIfNil(placemark.locality),
                                  @"district": ABI43_0_0EXNullIfNil(placemark.subLocality),
                                  @"street": ABI43_0_0EXNullIfNil(placemark.thoroughfare),
                                  @"region": ABI43_0_0EXNullIfNil(placemark.administrativeArea),
                                  @"subregion": ABI43_0_0EXNullIfNil(placemark.subAdministrativeArea),
                                  @"country": ABI43_0_0EXNullIfNil(placemark.country),
                                  @"postalCode": ABI43_0_0EXNullIfNil(placemark.postalCode),
                                  @"name": ABI43_0_0EXNullIfNil(placemark.name),
                                  @"isoCountryCode": ABI43_0_0EXNullIfNil(placemark.ISOcountryCode),
                                  @"timezone": ABI43_0_0EXNullIfNil(placemark.timeZone.name),
                                  };
        [results addObject:address];
      }
      resolve(results);
    } else if (error.code == kCLErrorGeocodeFoundNoResult || error.code == kCLErrorGeocodeFoundPartialResult) {
      resolve(@[]);
    } else if (error.code == kCLErrorNetwork) {
      reject(@"E_RATE_EXCEEDED", @"Rate limit exceeded - too many requests", error);
    } else {
      reject(@"E_REVGEOCODING_FAILED", @"Error while reverse-geocoding a location", error);
    }
  }];
}

ABI43_0_0EX_EXPORT_METHOD_AS(getPermissionsAsync,
                    getPermissionsAsync:(ABI43_0_0EXPromiseResolveBlock)resolve
                    rejecter:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  [ABI43_0_0EXPermissionsMethodsDelegate getPermissionWithPermissionsManager:_permissionsManager
                                                      withRequester:[ABI43_0_0EXLocationPermissionRequester class]
                                                            resolve:resolve
                                                             reject:reject];
}

ABI43_0_0EX_EXPORT_METHOD_AS(requestPermissionsAsync,
                    requestPermissionsAsync:(ABI43_0_0EXPromiseResolveBlock)resolve
                    rejecter:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  [ABI43_0_0EXPermissionsMethodsDelegate askForPermissionWithPermissionsManager:_permissionsManager
                                                         withRequester:[ABI43_0_0EXLocationPermissionRequester class]
                                                               resolve:resolve
                                                                reject:reject];
}

ABI43_0_0EX_EXPORT_METHOD_AS(getForegroundPermissionsAsync,
                    getForegroundPermissionsAsync:(ABI43_0_0EXPromiseResolveBlock)resolve
                    rejecter:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  [ABI43_0_0EXPermissionsMethodsDelegate getPermissionWithPermissionsManager:_permissionsManager
                                                      withRequester:[ABI43_0_0EXForegroundPermissionRequester class]
                                                            resolve:resolve
                                                             reject:reject];
}

ABI43_0_0EX_EXPORT_METHOD_AS(requestForegroundPermissionsAsync,
                    requestForegroundPermissionsAsync:(ABI43_0_0EXPromiseResolveBlock)resolve
                    rejecter:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  [ABI43_0_0EXPermissionsMethodsDelegate askForPermissionWithPermissionsManager:_permissionsManager
                                                         withRequester:[ABI43_0_0EXForegroundPermissionRequester class]
                                                               resolve:resolve
                                                                reject:reject];
}

ABI43_0_0EX_EXPORT_METHOD_AS(getBackgroundPermissionsAsync,
                    getBackgroundPermissionsAsync:(ABI43_0_0EXPromiseResolveBlock)resolve
                    rejecter:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  [ABI43_0_0EXPermissionsMethodsDelegate getPermissionWithPermissionsManager:_permissionsManager
                                                      withRequester:[ABI43_0_0EXBackgroundLocationPermissionRequester class]
                                                            resolve:resolve
                                                             reject:reject];
}

ABI43_0_0EX_EXPORT_METHOD_AS(requestBackgroundPermissionsAsync,
                    requestBackgroundPermissionsAsync:(ABI43_0_0EXPromiseResolveBlock)resolve
                    rejecter:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  [ABI43_0_0EXPermissionsMethodsDelegate askForPermissionWithPermissionsManager:_permissionsManager
                                                         withRequester:[ABI43_0_0EXBackgroundLocationPermissionRequester class]
                                                               resolve:resolve
                                                                reject:reject];
}

ABI43_0_0EX_EXPORT_METHOD_AS(hasServicesEnabledAsync,
                    hasServicesEnabled:(ABI43_0_0EXPromiseResolveBlock)resolve
                    reject:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  BOOL servicesEnabled = [CLLocationManager locationServicesEnabled];
  resolve(@(servicesEnabled));
}

# pragma mark - Background location

ABI43_0_0EX_EXPORT_METHOD_AS(startLocationUpdatesAsync,
                    startLocationUpdatesForTaskWithName:(nonnull NSString *)taskName
                    withOptions:(nonnull NSDictionary *)options
                    resolve:(ABI43_0_0EXPromiseResolveBlock)resolve
                    reject:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  // There are two ways of starting this service.
  // 1. As a background location service, this requires the background location permission.
  // 2. As a user-initiated foreground service, this does NOT require the background location permission.
  // Unfortunately, we cannot distinguish between those cases.
  // So we only check foreground permission which needs to be granted in both cases.
  if (![self checkForegroundPermissions:reject] || ![self checkTaskManagerExists:reject] || ![self checkBackgroundServices:reject]) {
    return;
  }
  if (![CLLocationManager significantLocationChangeMonitoringAvailable]) {
    return reject(@"E_SIGNIFICANT_CHANGES_UNAVAILABLE", @"Significant location changes monitoring is not available.", nil);
  }

  @try {
    [_tasksManager registerTaskWithName:taskName consumer:[ABI43_0_0EXLocationTaskConsumer class] options:options];
  }
  @catch (NSException *e) {
    return reject(e.name, e.reason, nil);
  }
  resolve(nil);
}

ABI43_0_0EX_EXPORT_METHOD_AS(stopLocationUpdatesAsync,
                    stopLocationUpdatesForTaskWithName:(NSString *)taskName
                    resolve:(ABI43_0_0EXPromiseResolveBlock)resolve
                    reject:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  if (![self checkTaskManagerExists:reject]) {
    return;
  }

  @try {
    [_tasksManager unregisterTaskWithName:taskName consumerClass:[ABI43_0_0EXLocationTaskConsumer class]];
  } @catch (NSException *e) {
    return reject(e.name, e.reason, nil);
  }
  resolve(nil);
}

ABI43_0_0EX_EXPORT_METHOD_AS(hasStartedLocationUpdatesAsync,
                    hasStartedLocationUpdatesForTaskWithName:(nonnull NSString *)taskName
                    resolve:(ABI43_0_0EXPromiseResolveBlock)resolve
                    reject:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  if (![self checkTaskManagerExists:reject]) {
    return;
  }

  resolve(@([_tasksManager taskWithName:taskName hasConsumerOfClass:[ABI43_0_0EXLocationTaskConsumer class]]));
}

# pragma mark - Geofencing

ABI43_0_0EX_EXPORT_METHOD_AS(startGeofencingAsync,
                    startGeofencingWithTaskName:(nonnull NSString *)taskName
                    withOptions:(nonnull NSDictionary *)options
                    resolve:(ABI43_0_0EXPromiseResolveBlock)resolve
                    reject:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  if (![self checkBackgroundPermissions:reject] || ![self checkTaskManagerExists:reject]) {
    return;
  }
  if (![CLLocationManager isMonitoringAvailableForClass:[CLCircularRegion class]]) {
    return reject(@"E_GEOFENCING_UNAVAILABLE", @"Geofencing is not available", nil);
  }

  @try {
    [_tasksManager registerTaskWithName:taskName consumer:[ABI43_0_0EXGeofencingTaskConsumer class] options:options];
  } @catch (NSException *e) {
    return reject(e.name, e.reason, nil);
  }
  resolve(nil);
}

ABI43_0_0EX_EXPORT_METHOD_AS(stopGeofencingAsync,
                    stopGeofencingWithTaskName:(nonnull NSString *)taskName
                    resolve:(ABI43_0_0EXPromiseResolveBlock)resolve
                    reject:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  if (![self checkTaskManagerExists:reject]) {
    return;
  }

  @try {
    [_tasksManager unregisterTaskWithName:taskName consumerClass:[ABI43_0_0EXGeofencingTaskConsumer class]];
  } @catch (NSException *e) {
    return reject(e.name, e.reason, nil);
  }
  resolve(nil);
}

ABI43_0_0EX_EXPORT_METHOD_AS(hasStartedGeofencingAsync,
                    hasStartedGeofencingForTaskWithName:(NSString *)taskName
                    resolve:(ABI43_0_0EXPromiseResolveBlock)resolve
                    reject:(ABI43_0_0EXPromiseRejectBlock)reject)
{
  if (![self checkTaskManagerExists:reject]) {
    return;
  }

  resolve(@([_tasksManager taskWithName:taskName hasConsumerOfClass:[ABI43_0_0EXGeofencingTaskConsumer class]]));
}

# pragma mark - helpers

- (CLLocationManager *)locationManagerWithOptions:(nullable NSDictionary *)options
{
  CLLocationManager *locMgr = [[CLLocationManager alloc] init];
  locMgr.allowsBackgroundLocationUpdates = NO;

  if (options) {
    locMgr.distanceFilter = options[@"distanceInterval"] ? [options[@"distanceInterval"] doubleValue] ?: kCLDistanceFilterNone : kCLLocationAccuracyHundredMeters;

    if (options[@"accuracy"]) {
      ABI43_0_0EXLocationAccuracy accuracy = [options[@"accuracy"] unsignedIntegerValue] ?: ABI43_0_0EXLocationAccuracyBalanced;
      locMgr.desiredAccuracy = [self.class CLLocationAccuracyFromOption:accuracy];
    }
  }
  return locMgr;
}

- (BOOL)checkForegroundPermissions:(ABI43_0_0EXPromiseRejectBlock)reject
{
  if (![CLLocationManager locationServicesEnabled]) {
    reject(@"E_LOCATION_SERVICES_DISABLED", @"Location services are disabled", nil);
    return NO;
  }
  if (![_permissionsManager hasGrantedPermissionUsingRequesterClass:[ABI43_0_0EXForegroundPermissionRequester class]]) {
    reject(@"E_NO_PERMISSIONS", @"LOCATION_FOREGROUND permission is required to do this operation.", nil);
    return NO;
  }
  return YES;
}

- (BOOL)checkBackgroundPermissions:(ABI43_0_0EXPromiseRejectBlock)reject
{
  if (![CLLocationManager locationServicesEnabled]) {
    reject(@"E_LOCATION_SERVICES_DISABLED", @"Location services are disabled", nil);
    return NO;
  }
  if (![_permissionsManager hasGrantedPermissionUsingRequesterClass:[ABI43_0_0EXBackgroundLocationPermissionRequester class]]) {
    reject(@"E_NO_PERMISSIONS", @"LOCATION_BACKGROUND permission is required to do this operation.", nil);
    return NO;
  }
  return YES;
}

- (BOOL)checkTaskManagerExists:(ABI43_0_0EXPromiseRejectBlock)reject
{
  if (_tasksManager == nil) {
    reject(@"E_TASKMANAGER_NOT_FOUND", @"`expo-task-manager` module is required to use background services.", nil);
    return NO;
  }
  return YES;
}

- (BOOL)checkBackgroundServices:(ABI43_0_0EXPromiseRejectBlock)reject
{
  if (![_tasksManager hasBackgroundModeEnabled:@"location"]) {
    reject(@"E_BACKGROUND_SERVICES_DISABLED", @"Background Location has not been configured. To enable it, add `location` to `UIBackgroundModes` in Info.plist file.", nil);
    return NO;
  }
  return YES;
}

# pragma mark - static helpers

+ (NSDictionary *)exportLocation:(CLLocation *)location
{
  return @{
    @"coords": @{
        @"latitude": @(location.coordinate.latitude),
        @"longitude": @(location.coordinate.longitude),
        @"altitude": @(location.altitude),
        @"accuracy": @(location.horizontalAccuracy),
        @"altitudeAccuracy": @(location.verticalAccuracy),
        @"heading": @(location.course),
        @"speed": @(location.speed),
        },
    @"timestamp": @([location.timestamp timeIntervalSince1970] * 1000),
    };
}

+ (CLLocationAccuracy)CLLocationAccuracyFromOption:(ABI43_0_0EXLocationAccuracy)accuracy
{
  switch (accuracy) {
    case ABI43_0_0EXLocationAccuracyLowest:
      return kCLLocationAccuracyThreeKilometers;
    case ABI43_0_0EXLocationAccuracyLow:
      return kCLLocationAccuracyKilometer;
    case ABI43_0_0EXLocationAccuracyBalanced:
      return kCLLocationAccuracyHundredMeters;
    case ABI43_0_0EXLocationAccuracyHigh:
      return kCLLocationAccuracyNearestTenMeters;
    case ABI43_0_0EXLocationAccuracyHighest:
      return kCLLocationAccuracyBest;
    case ABI43_0_0EXLocationAccuracyBestForNavigation:
      return kCLLocationAccuracyBestForNavigation;
    default:
      return kCLLocationAccuracyHundredMeters;
  }
}

+ (CLActivityType)CLActivityTypeFromOption:(NSInteger)activityType
{
  if (activityType >= CLActivityTypeOther && activityType <= CLActivityTypeOtherNavigation) {
    return activityType;
  }
  if (@available(iOS 12.0, *)) {
    if (activityType == CLActivityTypeAirborne) {
      return activityType;
    }
  }
  return CLActivityTypeOther;
}

+ (BOOL)isLocation:(nullable CLLocation *)location validWithOptions:(nullable NSDictionary *)options
{
  if (location == nil) {
    return NO;
  }
  NSTimeInterval maxAge = options[@"maxAge"] ? [options[@"maxAge"] doubleValue] : DBL_MAX;
  CLLocationAccuracy requiredAccuracy = options[@"requiredAccuracy"] ? [options[@"requiredAccuracy"] doubleValue] : DBL_MAX;
  NSTimeInterval timeDiff = -location.timestamp.timeIntervalSinceNow;

  return location != nil && timeDiff * 1000 <= maxAge && location.horizontalAccuracy <= requiredAccuracy;
}

@end

NS_ASSUME_NONNULL_END
