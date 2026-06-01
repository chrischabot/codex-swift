import * as React from "react";
import * as AvatarPrimitive from "@radix-ui/react-avatar";
import { cn } from "@/lib/utils";

// Original user avatars are circular (profile-dropdown.js:2385 + the
// rounded-full badge wrappers). Default to `rounded-full`; callers showing a
// square app/source icon can pass `shape="square"` (rounded-md).
type AvatarShape = "circle" | "square";

const AvatarShapeContext = React.createContext<AvatarShape>("circle");

const shapeClass = (shape: AvatarShape) =>
  shape === "square" ? "rounded-md" : "rounded-full";

const Avatar = React.forwardRef<
  React.ElementRef<typeof AvatarPrimitive.Root>,
  React.ComponentPropsWithoutRef<typeof AvatarPrimitive.Root> & {
    shape?: AvatarShape;
  }
>(({ className, shape = "circle", ...props }, ref) => (
  <AvatarShapeContext.Provider value={shape}>
    <AvatarPrimitive.Root
      ref={ref}
      className={cn(
        "relative flex h-8 w-8 shrink-0 overflow-hidden",
        shapeClass(shape),
        className,
      )}
      {...props}
    />
  </AvatarShapeContext.Provider>
));
Avatar.displayName = AvatarPrimitive.Root.displayName;

const AvatarImage = React.forwardRef<
  React.ElementRef<typeof AvatarPrimitive.Image>,
  React.ComponentPropsWithoutRef<typeof AvatarPrimitive.Image>
>(({ className, ...props }, ref) => (
  <AvatarPrimitive.Image
    ref={ref}
    className={cn("aspect-square h-full w-full", className)}
    {...props}
  />
));
AvatarImage.displayName = AvatarPrimitive.Image.displayName;

const AvatarFallback = React.forwardRef<
  React.ElementRef<typeof AvatarPrimitive.Fallback>,
  React.ComponentPropsWithoutRef<typeof AvatarPrimitive.Fallback>
>(({ className, ...props }, ref) => {
  const shape = React.useContext(AvatarShapeContext);
  return (
    <AvatarPrimitive.Fallback
      ref={ref}
      className={cn(
        "flex h-full w-full items-center justify-center bg-[color:var(--color-surface-hover)] text-[12px] font-medium",
        shapeClass(shape),
        className,
      )}
      {...props}
    />
  );
});
AvatarFallback.displayName = AvatarPrimitive.Fallback.displayName;

export { Avatar, AvatarImage, AvatarFallback };
