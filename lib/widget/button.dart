
import 'package:ensemble/framework/action.dart' as ensemble;
import 'package:ensemble/layout/form.dart';
import 'package:ensemble/layout/layout_helper.dart';
import 'package:ensemble/screen_controller.dart';
import 'package:ensemble/util/theme_utils.dart';
import 'package:ensemble/util/utils.dart';
import 'package:ensemble/framework/widget/widget.dart';
import 'package:flutter/material.dart';
import 'package:ensemble/layout/form.dart' as ensembleForm;
import 'package:ensemble_ts_interpreter/invokables/invokable.dart';

class Button extends StatefulWidget with Invokable, HasController<ButtonController, ButtonState> {
  static const type = 'Button';
  Button({Key? key}) : super(key: key);

  final ButtonController _controller = ButtonController();
  @override
  ButtonController get controller => _controller;

  @override
  Map<String, Function> getters() {
    return {};
  }
  @override
  Map<String, Function> setters() {
    return {
      'label': (value) => _controller.label = Utils.getString(value, fallback: ''),
      'onTap': (funcDefinition) => _controller.onTap = Utils.getAction(funcDefinition, initiator: this),
      'validateForm': (value) => _controller.validateForm = Utils.optionalBool(value),
      'validateFields': (items) => _controller.validateFields = Utils.getList(items),

      'enabled': (value) => _controller.enabled = Utils.optionalBool(value),
      'outline': (value) => _controller.outline = Utils.optionalBool(value),
      'backgroundColor': (value) => _controller.backgroundColor = Utils.getColor(value),
      'color': (value) => _controller.color = Utils.getColor(value),
    };
  }
  @override
  Map<String, Function> methods() {
    return {};
  }

  @override
  State<StatefulWidget> createState() => ButtonState();

}

class ButtonController extends BoxController {
  ensemble.EnsembleAction? onTap;

  // whether this button will invoke form validation or not
  // this has no effect if the button is not inside a form
  bool? validateForm;

  // a list of field IDs to validate. TODO: implement this
  List<dynamic>? validateFields;

  bool? enabled;
  bool? outline;
  Color? backgroundColor;
  Color? color;
}


class ButtonState extends WidgetState<Button> {
  @override
  Widget build(BuildContext context) {
    if (!widget._controller.visible) {
      return const SizedBox.shrink();
    }

    bool isOutlineButton = widget._controller.outline ?? false;
    
    Text label = Text(Utils.translate(widget._controller.label ?? '', context));

    Widget? rtn;
    if (isOutlineButton) {
      rtn = TextButton(
        onPressed: isEnabled() ? () => onPressed(context) : null,
        style: getButtonStyle(context, isOutlineButton),
        child: label);
    } else {
      rtn = ElevatedButton(
        onPressed: isEnabled() ? () => onPressed(context) : null,
        style: getButtonStyle(context, isOutlineButton),
        child: label);
    }

    // add margin if specified
    return widget._controller.margin != null ?
      Padding(padding: widget._controller.margin!, child: rtn) :
      rtn;
  }
  
  ButtonStyle getButtonStyle(BuildContext context, bool isOutlineButton) {
    // we need to build a border which requires valid borderColor, borderThickness & borderRadius.
    // Let's get the default theme so we can overwrite only necessary styles
    RoundedRectangleBorder? border;
    OutlinedBorder? defaultShape = isOutlineButton ?
      Theme.of(context).textButtonTheme.style?.shape?.resolve({}) :
        Theme.of(context).elevatedButtonTheme.style?.shape?.resolve({});
    if (defaultShape is RoundedRectangleBorder) {
      // if we don't specify borderColor here, and the default border is none, stick with that
      BorderSide borderSide;
      if (widget._controller.borderColor == null && defaultShape.side.style == BorderStyle.none) {
        borderSide = defaultShape.side;
      } else {
        borderSide = BorderSide(
            color: widget._controller.borderColor ?? defaultShape.side.color,
            width: widget._controller.borderWidth?.toDouble() ?? defaultShape.side.width);
      }

      border = RoundedRectangleBorder(
        borderRadius: widget._controller.borderRadius == null ?
            defaultShape.borderRadius :
            BorderRadius.circular(widget._controller.borderRadius!.toDouble()),
        side: borderSide);
    }
        
    // we need to get the button shape from borderRadius, borderColor & borderThickness
    // and we do not want to override the default theme if not specified
    //int borderRadius = widget._controller.borderRadius ?? defaultButtonStyle?.

    return ThemeUtils.getButtonStyle(
        isOutline: isOutlineButton,
        color: widget._controller.color,
        backgroundColor: widget._controller.backgroundColor,
        border: border,
        padding: widget._controller.padding
    );
  }

  void onPressed(BuildContext context) {
    // validate if we are inside a Form
    if (widget._controller.validateForm != null && widget._controller.validateForm!) {
      ensembleForm.FormState? formState = EnsembleForm.of(context);
      if (formState != null) {
        // don't continue if validation fails
        if (!formState.validate()) {
          return;
        }
      }
    }
    // else validate specified fields
    else if (widget._controller.validateFields != null) {

    }

    // execute the onTap action
    if (widget._controller.onTap != null) {
      ScreenController().executeAction(context, widget._controller.onTap!);
    }
  }

  bool isEnabled() {
    return widget._controller.enabled
        ?? EnsembleForm.of(context)?.widget.controller.enabled
        ?? true;
  }

}