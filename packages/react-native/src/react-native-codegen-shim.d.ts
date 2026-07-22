/** Local compile shim; consumers resolve these exports from their React Native peer dependency. */
declare module 'react-native' {
  export interface TurboModule {}

  export const TurboModuleRegistry: {
    getEnforcing<T extends TurboModule>(name: string): T;
  };
}

declare module 'react-native/Libraries/Types/CodegenTypes' {
  export interface EventSubscription {
    remove(): void;
  }

  export type EventEmitter<T> = (listener: (payload: T) => void) => EventSubscription;
}
