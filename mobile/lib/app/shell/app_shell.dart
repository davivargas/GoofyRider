import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.navigationShell,
  });

  final StatefulNavigationShell navigationShell;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static const double _swipeVelocityThreshold = 400;
  static const double _swipeDistanceThreshold = 70;
  double _dragDx = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (DragUpdateDetails details) {
          _dragDx += details.delta.dx;
        },
        onHorizontalDragEnd: (DragEndDetails details) {
          _onHorizontalDragEnd(context, details);
        },
        onHorizontalDragCancel: () {
          _dragDx = 0;
        },
        child: widget.navigationShell,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: widget.navigationShell.currentIndex,
        onDestinationSelected: _goToBranch,
        destinations: <NavigationDestination>[
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          const NavigationDestination(
            icon: Icon(Icons.terrain_outlined),
            selectedIcon: Icon(Icons.terrain),
            label: 'Resorts',
          ),
          NavigationDestination(
            icon: _recordIcon(context, selected: false),
            selectedIcon: _recordIcon(context, selected: true),
            label: 'Record',
          ),
          const NavigationDestination(
            icon: Icon(Icons.history_toggle_off),
            selectedIcon: Icon(Icons.history),
            label: 'History',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }

  void _onHorizontalDragEnd(BuildContext context, DragEndDetails details) {
    final double velocity = details.primaryVelocity ?? 0;

    final swipedLeft = _dragDx <= -_swipeDistanceThreshold ||
        velocity <= -_swipeVelocityThreshold;

    final swipedRight = _dragDx >= _swipeDistanceThreshold ||
        velocity >= _swipeVelocityThreshold;

    _dragDx = 0;
    if(!swipedLeft && !swipedRight) {
      return;
    }

    final int tabCount = 5;
    final int currentIndex = widget.navigationShell.currentIndex;
    final int nextIndex = swipedLeft ? currentIndex + 1 : currentIndex - 1;

    if (nextIndex < 0 || nextIndex >= tabCount) {
      return;
    }
    _goToBranch(nextIndex);
  }

  void _goToBranch(int index) {
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.navigationShell.currentIndex,
    );
  }

  Widget _recordIcon(BuildContext context, {required bool selected}) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color:
            selected ? scheme.primary : scheme.primary.withValues(alpha: 0.2),
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.fiber_manual_record,
        color: selected ? Colors.white : scheme.primary,
        size: 16,
      ),
    );
  }
}
